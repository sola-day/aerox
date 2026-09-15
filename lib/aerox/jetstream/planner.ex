defmodule Aerox.Jetstream.Planner do
  @moduledoc """
  `network.bsky.jetstream.planSnapshot` (upstream `manifest.PlanSnapshot`):
  which sealed segments, or which block ranges in them, may hold events
  matching kinds, DIDs and collections within an `(afterSeq, beforeSeq]`
  window — from manifest metadata only (seq bounds, DID blooms, collection
  indexes), never opening a segment. No false negatives; false positives are
  the client's exact filter's job. A segment where at least
  `plan_whole_segment_threshold` of the blocks match is planned whole. Pages
  stop at a whole unit once `plan_max_entries` entries are planned, and
  `plannedThroughSeq` is that unit's max seq.
  """
  alias Aerox.Jetstream.{Config, Gloom, Manifest}

  @kinds %{"commit" => 1, "identity" => 2, "account" => 4, "sync" => 8}
  @sentinels %{"$account" => 4, "$identity" => 2, "$sync" => 8}

  @doc "Validates a planSnapshot input into a request (upstream `planRequestFromInput`)."
  def request(input) do
    with {:ok, kinds} <- kinds(input["kinds"] || []),
         {:ok, dids} <- dids(input["dids"] || []),
         {:ok, exact, prefixes} <- collections(input["collections"] || []),
         :ok <-
           if((exact != [] or prefixes != []) and kinds != 0 and Bitwise.band(kinds, 1) == 0,
             do: {:error, "collections filter can never apply: kinds excludes commit"},
             else: :ok
           ),
         {:ok, after_seq} <- seq_param(input, "afterSeq"),
         {:ok, before_seq} <- seq_param(input, "beforeSeq"),
         :ok <-
           if(after_seq && before_seq && before_seq <= after_seq,
             do: {:error, "beforeSeq must be greater than afterSeq"},
             else: :ok
           ) do
      {:ok,
       %{
         kinds: kinds,
         dids: dids,
         exact: MapSet.new(exact),
         prefixes: prefixes,
         after: after_seq,
         before: before_seq
       }}
    end
  end

  defp kinds(raw) when length(raw) > 4, do: {:error, "too many kinds"}

  defp kinds(raw) do
    Enum.reduce_while(raw, {:ok, 0}, fn k, {:ok, acc} ->
      case @kinds[k] do
        nil -> {:halt, {:error, "invalid kind: #{k}"}}
        bit -> {:cont, {:ok, Bitwise.bor(acc, bit)}}
      end
    end)
  end

  defp dids([]), do: {:ok, []}

  defp dids(raw) do
    max = Config.plan_max_dids()

    cond do
      max == 0 ->
        {:error, "DID filters are disabled"}

      length(raw) > max ->
        {:error, "too many DIDs"}

      true ->
        case Enum.find(raw, &(not Aerox.ATProto.Syntax.valid_did?(&1))) do
          nil -> {:ok, Enum.uniq(raw)}
          bad -> {:error, "invalid DID: #{bad}"}
        end
    end
  end

  defp collections([]), do: {:ok, [], []}

  defp collections(raw) do
    max = Config.plan_max_collections()

    cond do
      max == 0 ->
        {:error, "collection filters are disabled"}

      length(raw) > max ->
        {:error, "too many collections"}

      true ->
        raw
        |> Enum.uniq()
        |> Enum.reduce_while({:ok, [], []}, fn value, {:ok, ex, pre} ->
          case String.split(value, ".*") do
            [head, ""] ->
              if Aerox.ATProto.Syntax.valid_nsid?(head <> ".x"),
                do: {:cont, {:ok, ex, pre ++ [head <> "."]}},
                else: {:halt, {:error, "invalid collection wildcard: #{value}"}}

            _ ->
              if Aerox.ATProto.Syntax.valid_nsid?(value),
                do: {:cont, {:ok, ex ++ [value], pre}},
                else: {:halt, {:error, "invalid collection: #{value}"}}
          end
        end)
    end
  end

  defp seq_param(input, key) do
    case input[key] do
      nil -> {:ok, nil}
      n when is_integer(n) and n >= 0 -> {:ok, n}
      _ -> {:error, "#{key} must be >= 0"}
    end
  end

  # ---------------------------------------------------------------- plan

  @spec plan(map) :: map
  def plan(req) do
    segments = Manifest.sealed()
    tip = segments |> Enum.map(& &1.header.max_seq) |> Enum.max(fn -> 0 end)
    tip = if req.before && req.before < tip, do: req.before, else: tip
    max_entries = Config.plan_max_entries()
    threshold = Config.plan_whole_segment_threshold()

    acc = %{
      segments: [],
      entries: 0,
      examined: 0,
      matched: 0,
      blocks: 0,
      last_unit: 0,
      truncated: false
    }

    acc =
      Enum.reduce_while(segments, acc, fn seg, acc ->
        acc = %{acc | examined: acc.examined + 1}
        at_cap? = fn acc -> max_entries > 0 and acc.entries >= max_entries end

        with true <- segment_overlaps?(seg, req),
             [_ | _] = selected <- select_blocks(seg, req) do
          density = length(selected) / max(length(seg.blocks), 1)

          planned = %{
            "name" => Aerox.Jetstream.Segment.filename(seg.idx),
            "index" => seg.idx,
            "checksum" => hex(seg.header.checksum),
            "minSeq" => seg.header.min_seq,
            "maxSeq" => seg.header.max_seq
          }

          if density >= threshold do
            if at_cap?.(acc) do
              {:halt, %{acc | truncated: true}}
            else
              {:cont,
               %{
                 acc
                 | segments: acc.segments ++ [Map.put(planned, "mode", "segment")],
                   entries: acc.entries + 1,
                   matched: acc.matched + 1,
                   blocks: acc.blocks + length(selected),
                   last_unit: seg.header.max_seq
               }}
            end
          else
            {ranges, acc} =
              Enum.reduce_while(coalesce(selected), {[], acc}, fn {first, last}, {ranges, acc} ->
                if at_cap?.(acc) do
                  {:halt, {ranges, %{acc | truncated: true}}}
                else
                  {:cont,
                   {ranges ++ [%{"first" => first, "last" => last}],
                    %{
                      acc
                      | entries: acc.entries + 1,
                        blocks: acc.blocks + last - first + 1,
                        last_unit: Enum.at(seg.blocks, last).max_seq
                    }}}
                end
              end)

            acc =
              if ranges != [],
                do: %{
                  acc
                  | matched: acc.matched + 1,
                    segments:
                      acc.segments ++
                        [planned |> Map.put("mode", "blocks") |> Map.put("blocks", ranges)]
                },
                else: acc

            if acc.truncated, do: {:halt, acc}, else: {:cont, acc}
          end
        else
          _ -> {:cont, acc}
        end
      end)

    %{
      "plannedThroughSeq" => if(acc.truncated, do: acc.last_unit, else: tip),
      "sealedTipSeq" => tip,
      "segments" => acc.segments,
      "stats" => %{
        "segmentsExamined" => acc.examined,
        "segmentsMatched" => acc.matched,
        "blocksMatched" => acc.blocks,
        "entries" => acc.entries
      }
    }
  end

  defp segment_overlaps?(seg, req) do
    seg.blocks != [] and seg.header.event_count > 0 and
      not (req.after != nil and seg.header.max_seq <= req.after) and
      not (req.before != nil and seg.header.min_seq > req.before)
  end

  defp block_overlaps?(b, req) do
    b.event_count > 0 and not (req.after != nil and b.max_seq <= req.after) and
      not (req.before != nil and b.min_seq > req.before)
  end

  defp select_blocks(seg, req) do
    collection_all? = MapSet.size(req.exact) == 0 and req.prefixes == []
    candidate_all? = req.kinds == 0 and collection_all?
    did_all? = req.dids == []

    cond do
      not did_all? and not Enum.any?(req.dids, &Gloom.member?(seg.segment_bloom, &1)) ->
        []

      true ->
        candidates = if candidate_all?, do: nil, else: candidates(seg, req, collection_all?)

        if candidates != nil and MapSet.size(candidates.included) == 0 and
             not (candidates.all_real and candidates.has_real) do
          []
        else
          for {b, i} <- Enum.with_index(seg.blocks),
              block_overlaps?(b, req),
              candidate_all? or block_has_candidate?(seg, i, candidates),
              did_all? or Enum.any?(req.dids, &Gloom.member?(Enum.at(seg.block_blooms, i), &1)),
              do: i
        end
    end
  end

  defp admits?(0, _), do: true
  defp admits?(mask, bit), do: Bitwise.band(mask, bit) != 0

  defp candidates(seg, req, collection_all?) do
    seg.collections
    |> Enum.with_index()
    |> Enum.reduce(
      %{
        included: MapSet.new(),
        sentinels: MapSet.new(),
        all_real: collection_all? and admits?(req.kinds, 1),
        has_real: false
      },
      fn {name, id}, acc ->
        case @sentinels[name] do
          nil ->
            if admits?(req.kinds, 1) do
              acc = %{acc | has_real: true}

              if not collection_all? and
                   (MapSet.member?(req.exact, name) or
                      Enum.any?(req.prefixes, &String.starts_with?(name, &1))),
                 do: %{acc | included: MapSet.put(acc.included, id)},
                 else: acc
            else
              acc
            end

          bit ->
            acc = %{acc | sentinels: MapSet.put(acc.sentinels, id)}

            if admits?(req.kinds, bit),
              do: %{acc | included: MapSet.put(acc.included, id)},
              else: acc
        end
      end
    )
  end

  defp block_has_candidate?(seg, i, c) do
    Enum.any?(Enum.at(seg.block_collections, i, []), fn id ->
      MapSet.member?(c.included, id) or (c.all_real and not MapSet.member?(c.sentinels, id))
    end)
  end

  defp coalesce([first | rest]) do
    {ranges, cur} =
      Enum.reduce(rest, {[], {first, first}}, fn b, {ranges, {f, l}} ->
        if b == l + 1, do: {ranges, {f, b}}, else: {ranges ++ [{f, l}], {b, b}}
      end)

    ranges ++ [cur]
  end

  defp hex(checksum),
    do: checksum |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(16, "0")
end
