defmodule Aerox.Jetstream.Segment do
  @moduledoc """
  Jetstream segment files (`.jss`, docs/README.md §3.1), byte for byte:

      header (256 bytes: "jss0", xxh3 checksum, version 1, counts, seq and
              witnessed-at bounds, section offsets; zero while active)
      blocks  (u64 length prefix + zstd frame, `Aerox.Jetstream.Block`)
      footer  (sealed only): block index (52 bytes per block) · segment DID
              bloom · per-block DID blooms (8-byte header + equal-size gloom
              filters) · collection block index (16-byte header + zstd body)

  The checksum is XXH3-64 over header bytes 12..255 followed by the footer.
  Sealing walks the frames, as upstream's `walkActiveFrames`; rewriting (for
  compaction and timestamp import) keeps block topology and the historical seq
  and witnessed-at bounds, as upstream's `Rewrite`.
  """
  import Bitwise
  alias Aerox.Jetstream.{Block, Event, Gloom, XXH3}

  @header_bytes 256
  @magic "jss0"
  @version 1
  @index_entry 52
  @fp 0.001

  def header_bytes, do: @header_bytes

  # --------------------------------------------------------------- names

  @doc "`seg_` + the index in base 36, zero-padded to 10 digits, + `.jss`."
  def filename(idx) do
    "seg_" <>
      (idx |> Integer.to_string(36) |> String.downcase() |> String.pad_leading(10, "0")) <> ".jss"
  end

  @doc "The index a segment filename encodes, if it is one."
  def parse_filename("seg_" <> <<mid::binary-size(10)>> <> ".jss" = name) do
    case Integer.parse(mid, 36) do
      {idx, ""} -> if filename(idx) == name, do: {:ok, idx}, else: :error
      _ -> :error
    end
  end

  def parse_filename(_), do: :error

  # ------------------------------------------------------------ building

  @doc "An active segment's header: the magic, then zeroes until sealing (a zero checksum marks it active)."
  def active_header, do: @magic <> :binary.copy(<<0>>, @header_bytes - 4)

  @doc "A length-prefixed frame as appended to a segment."
  def framed(frame), do: <<byte_size(frame)::little-64, frame::binary>>

  @doc """
  The sealed file for `blocks` (each `%{frame, events, uncompressed_size}`, in
  order): header, framed blocks, footer. `bounds` overrides the header's seq and
  witnessed-at bounds (a rewrite keeps the originals).
  """
  @spec seal([map], keyword) :: {binary, map}
  def seal(blocks, opts \\ []) do
    {pairs, footer_offset} =
      Enum.map_reduce(blocks, @header_bytes, fn b, offset ->
        info =
          Map.merge(
            %{
              offset: offset,
              compressed_size: byte_size(b.frame),
              uncompressed_size: b.uncompressed_size,
              event_count: length(b.events)
            },
            b[:bounds] || bounds(b.events)
          )

        {{info, summarize(b.events)}, offset + 8 + byte_size(b.frame)}
      end)

    {footer, header_bin, header} = build_footer(pairs, footer_offset, Keyword.get(opts, :bounds))
    {IO.iodata_to_binary([header_bin, Enum.map(blocks, &framed(&1.frame)), footer]), header}
  end

  @doc "A block's index entry bounds from its rows."
  def bounds([]), do: %{min_seq: 0, max_seq: 0, min_witnessed_at: 0, max_witnessed_at: 0}

  def bounds(events) do
    %{
      min_seq: events |> Enum.map(& &1.seq) |> Enum.min(),
      max_seq: events |> Enum.map(& &1.seq) |> Enum.max(),
      min_witnessed_at: events |> Enum.map(& &1.witnessed_at) |> Enum.min(),
      max_witnessed_at: events |> Enum.map(& &1.witnessed_at) |> Enum.max()
    }
  end

  @doc """
  What sealing needs to know about one block without its rows: the distinct
  DIDs, and the collection names (real ones and marker sentinels) in the order
  they first appear, with each real collection's row count. Summaries in block
  order intern names exactly as upstream's event-order walk does.
  """
  def summarize(events) do
    Enum.reduce(events, %{dids: MapSet.new(), names: [], counts: %{}}, fn e, acc ->
      acc = if e.did != "", do: %{acc | dids: MapSet.put(acc.dids, e.did)}, else: acc

      acc =
        if e.collection != "" do
          acc
          |> note_name(e.collection)
          |> Map.update!(:counts, &Map.update(&1, e.collection, 1, fn n -> n + 1 end))
        else
          acc
        end

      case Event.sentinel(e) do
        nil -> acc
        s -> note_name(acc, s)
      end
    end)
    |> Map.update!(:names, &Enum.reverse/1)
  end

  defp note_name(acc, name) do
    if name in acc.names, do: acc, else: %{acc | names: [name | acc.names]}
  end

  @doc """
  The footer and the finished header for blocks given as `{info, summary}`
  pairs (`info` as in the block index). `bounds` overrides the header's seq and
  witnessed-at bounds; by default they span the non-empty blocks.
  """
  def build_footer(pairs, footer_offset, bounds \\ nil) do
    infos = Enum.map(pairs, &elem(&1, 0))
    summaries = Enum.map(pairs, &elem(&1, 1))

    {table, ids, counts} =
      Enum.reduce(summaries, {[], %{}, %{}}, fn sum, acc ->
        Enum.reduce(sum.names, acc, fn name, {t, ids, c} ->
          if Map.has_key?(ids, name),
            do: {t, ids, c},
            else: {[name | t], Map.put(ids, name, map_size(ids)), c}
        end)
        |> then(fn {t, ids, c} -> {t, ids, Map.merge(c, sum.counts, fn _, a, b -> a + b end)} end)
      end)

    table = Enum.reverse(table)

    block_cols =
      Enum.map(summaries, fn sum -> sum.names |> Enum.map(&Map.fetch!(ids, &1)) |> Enum.sort() end)

    all_dids = Enum.reduce(summaries, MapSet.new(), &MapSet.union(&2, &1.dids))

    index = encode_block_index(infos)

    seg_bloom =
      all_dids
      |> Enum.reduce(Gloom.new(MapSet.size(all_dids), @fp), &Gloom.add(&2, &1))
      |> Gloom.marshal()

    capacity = summaries |> Enum.map(&MapSet.size(&1.dids)) |> Enum.max(fn -> 1 end) |> max(1)

    block_blooms =
      Enum.map(summaries, fn sum ->
        sum.dids |> Enum.reduce(Gloom.new(capacity, @fp), &Gloom.add(&2, &1)) |> Gloom.marshal()
      end)

    bloom_size =
      case block_blooms do
        [first | _] -> byte_size(first)
        [] -> 0
      end

    region =
      IO.iodata_to_binary([
        <<length(block_blooms)::little-32, bloom_size::little-32>> | block_blooms
      ])

    collection_index =
      encode_collection_index(table, Enum.map(table, &Map.get(counts, &1, 0)), block_cols)

    did_bloom_offset = footer_offset + byte_size(index)
    block_bloom_offset = did_bloom_offset + byte_size(seg_bloom)
    collection_offset = block_bloom_offset + byte_size(region)

    nonempty = Enum.filter(infos, &(&1.event_count > 0))

    bounds =
      bounds ||
        case nonempty do
          [] ->
            %{min_seq: 0, max_seq: 0, min_witnessed_at: 0, max_witnessed_at: 0}

          _ ->
            %{
              min_seq: nonempty |> Enum.map(& &1.min_seq) |> Enum.min(),
              max_seq: nonempty |> Enum.map(& &1.max_seq) |> Enum.max(),
              min_witnessed_at: nonempty |> Enum.map(& &1.min_witnessed_at) |> Enum.min(),
              max_witnessed_at: nonempty |> Enum.map(& &1.max_witnessed_at) |> Enum.max()
            }
        end

    header =
      Map.merge(bounds, %{
        version: @version,
        block_count: length(infos),
        event_count: infos |> Enum.map(& &1.event_count) |> Enum.sum(),
        unique_did_count: MapSet.size(all_dids),
        footer_offset: footer_offset,
        did_bloom_offset: did_bloom_offset,
        block_did_bloom_offset: block_bloom_offset,
        collection_index_offset: collection_offset,
        block_index_offset: footer_offset
      })

    footer = IO.iodata_to_binary([index, seg_bloom, region, collection_index])
    checksum = checksum(encode_header(header, 0), footer)
    header = Map.put(header, :checksum, checksum)
    {footer, encode_header(header, checksum), header}
  end

  defp encode_block_index(infos) do
    for i <- infos, into: <<>> do
      <<i.offset::little-64, i.compressed_size::little-32, i.uncompressed_size::little-32,
        i.event_count::little-32, i.min_seq::little-64, i.max_seq::little-64,
        i.min_witnessed_at::little-signed-64, i.max_witnessed_at::little-signed-64>>
    end
  end

  defp encode_collection_index(table, counts, block_cols) do
    bitmask_len = div(length(table) + 7, 8)

    body =
      IO.iodata_to_binary([
        Enum.zip_with(table, counts, fn name, count ->
          <<byte_size(name), count::little-32, name::binary>>
        end),
        Enum.map(block_cols, fn ids ->
          mask = Enum.reduce(ids, 0, fn id, acc -> acc ||| 1 <<< id end)
          # bit N of byte N/8, least significant bit first
          for byte <- 0..(bitmask_len - 1)//1, into: <<>>, do: <<mask >>> (byte * 8) &&& 0xFF>>
        end)
      ])

    <<length(table)::little-32, length(block_cols)::little-32, bitmask_len::little-32,
      byte_size(body)::little-32, Block.zstd(body)::binary>>
  end

  defp encode_header(h, checksum) do
    <<@magic, checksum::little-64, h.version::little-16, h.block_count::little-32,
      h.event_count::little-32, h.unique_did_count::little-32, h.min_seq::little-64,
      h.max_seq::little-64, h.min_witnessed_at::little-signed-64,
      h.max_witnessed_at::little-signed-64, h.footer_offset::little-64,
      h.did_bloom_offset::little-64, h.block_did_bloom_offset::little-64,
      h.collection_index_offset::little-64, h.block_index_offset::little-64, 0::size(158 * 8)>>
  end

  @doc "XXH3-64 over header bytes 12.. and the footer."
  def checksum(header_bin, footer) do
    <<_::binary-size(12), rest::binary>> = header_bin
    XXH3.hash64(rest <> footer)
  end

  # ------------------------------------------------------------- reading

  @doc "Parses a sealed header; an active (all-zero checksum) segment is `{:error, :active}`."
  @spec decode_header(binary) :: {:ok, map} | {:error, term}
  def decode_header(<<@magic, 0::little-64, _::binary-size(244)>>), do: {:error, :active}

  def decode_header(
        <<@magic, checksum::little-64, version::little-16, block_count::little-32,
          event_count::little-32, unique::little-32, min_seq::little-64, max_seq::little-64,
          min_w::little-signed-64, max_w::little-signed-64, footer::little-64,
          did_bloom::little-64, block_bloom::little-64, collection::little-64,
          block_index::little-64, _::binary-size(158)>>
      ) do
    if version != @version do
      {:error, {:unsupported_version, version}}
    else
      {:ok,
       %{
         checksum: checksum,
         version: version,
         block_count: block_count,
         event_count: event_count,
         unique_did_count: unique,
         min_seq: min_seq,
         max_seq: max_seq,
         min_witnessed_at: min_w,
         max_witnessed_at: max_w,
         footer_offset: footer,
         did_bloom_offset: did_bloom,
         block_did_bloom_offset: block_bloom,
         collection_index_offset: collection,
         block_index_offset: block_index
       }}
    end
  end

  def decode_header(<<magic::binary-size(4), _::binary>>) when magic != @magic,
    do: {:error, :bad_magic}

  def decode_header(_), do: {:error, :invalid_header}

  @doc """
  Everything a sealed file's metadata says: header, block infos, the segment
  bloom, per-block blooms, the collection table with counts and each block's
  collection ids. Verifies the checksum unless `verify: false`.
  """
  @spec parse(binary, keyword) :: {:ok, map} | {:error, term}
  def parse(file, opts \\ []) when is_binary(file) do
    with <<header_bin::binary-size(@header_bytes), _::binary>> <- file,
         {:ok, h} <- decode_header(header_bin),
         true <- byte_size(file) >= h.footer_offset || {:error, :truncated},
         footer = binary_part(file, h.footer_offset, byte_size(file) - h.footer_offset),
         :ok <- if(Keyword.get(opts, :verify, true), do: verify(header_bin, footer, h), else: :ok) do
      parse_footer(h, footer)
    else
      {:error, _} = e -> e
      _ -> {:error, :invalid_segment}
    end
  end

  @doc "Parses the footer given its header (the bytes from `footer_offset` to the end)."
  def parse_footer(h, footer) do
    rel = fn off -> off - h.footer_offset end
    index_len = h.block_count * @index_entry

    with <<index::binary-size(^index_len), _::binary>> <- footer,
         seg_bloom_bin =
           binary_part(
             footer,
             rel.(h.did_bloom_offset),
             h.block_did_bloom_offset - h.did_bloom_offset
           ),
         region =
           binary_part(
             footer,
             rel.(h.block_did_bloom_offset),
             h.collection_index_offset - h.block_did_bloom_offset
           ),
         collection_bin =
           binary_part(
             footer,
             rel.(h.collection_index_offset),
             byte_size(footer) - rel.(h.collection_index_offset)
           ),
         {:ok, seg_bloom} <- Gloom.unmarshal(seg_bloom_bin),
         {:ok, block_blooms} <- decode_bloom_region(region),
         {:ok, collections} <- decode_collection_index(collection_bin) do
      {:ok,
       %{
         header: h,
         blocks: decode_block_index(index),
         segment_bloom: seg_bloom,
         block_blooms: block_blooms,
         collections: collections.table,
         collection_counts: collections.counts,
         block_collections: collections.blocks
       }}
    else
      {:error, _} = e -> e
      _ -> {:error, :invalid_footer}
    end
  end

  defp verify(header_bin, footer, h) do
    if checksum(header_bin, footer) == h.checksum, do: :ok, else: {:error, :checksum_mismatch}
  end

  defp decode_block_index(bin) do
    for <<offset::little-64, csize::little-32, usize::little-32, count::little-32,
          min_seq::little-64, max_seq::little-64, min_w::little-signed-64,
          max_w::little-signed-64 <- bin>> do
      %{
        offset: offset,
        compressed_size: csize,
        uncompressed_size: usize,
        event_count: count,
        min_seq: min_seq,
        max_seq: max_seq,
        min_witnessed_at: min_w,
        max_witnessed_at: max_w
      }
    end
  end

  defp decode_bloom_region(<<count::little-32, size::little-32, body::binary>>) do
    if count * size != byte_size(body) do
      {:error, :invalid_bloom_region}
    else
      Enum.reduce_while(0..(count - 1)//1, {:ok, []}, fn i, {:ok, acc} ->
        case Gloom.unmarshal(binary_part(body, i * size, size)) do
          {:ok, f} -> {:cont, {:ok, [f | acc]}}
          e -> {:halt, e}
        end
      end)
      |> case do
        {:ok, acc} -> {:ok, Enum.reverse(acc)}
        e -> e
      end
    end
  end

  defp decode_bloom_region(_), do: {:error, :invalid_bloom_region}

  defp decode_collection_index(
         <<count::little-32, blocks::little-32, mask_len::little-32, usize::little-32, z::binary>>
       ) do
    body = z |> :zstd.decompress() |> IO.iodata_to_binary()

    with true <- byte_size(body) == usize and mask_len == div(count + 7, 8),
         {:ok, table, counts, rest} <- read_table(body, count, [], []),
         true <- byte_size(rest) == blocks * mask_len do
      block_ids =
        for i <- 0..(blocks - 1)//1 do
          mask = binary_part(rest, i * mask_len, mask_len)

          for {byte, b} <- Enum.with_index(:binary.bin_to_list(mask)),
              bit <- 0..7,
              (byte >>> bit &&& 1) == 1,
              do: b * 8 + bit
        end

      {:ok, %{table: table, counts: counts, blocks: block_ids}}
    else
      _ -> {:error, :invalid_collection_index}
    end
  rescue
    _ -> {:error, :invalid_collection_index}
  end

  defp decode_collection_index(_), do: {:error, :invalid_collection_index}

  defp read_table(rest, 0, t, c), do: {:ok, Enum.reverse(t), Enum.reverse(c), rest}

  defp read_table(<<len, count::little-32, name::binary-size(len), rest::binary>>, n, t, c),
    do: read_table(rest, n - 1, [name | t], [count | c])

  defp read_table(_, _, _, _), do: :error

  @doc "The raw zstd frame of block `idx` (without its length prefix), from a parsed segment."
  def frame(file, %{blocks: blocks}, idx) do
    case Enum.at(blocks, idx) do
      nil -> {:error, :block_not_found}
      %{offset: off, compressed_size: size} -> {:ok, binary_part(file, off + 8, size)}
    end
  end

  @doc """
  Walks the frames of an active segment (from byte 256): `{:ok, blocks,
  end_offset}` for every complete frame, stopping at a torn tail, as upstream's
  crash recovery does.
  """
  def walk_active(bin) do
    walk(bin, @header_bytes, [])
  end

  defp walk(bin, off, acc) do
    case bin do
      <<_::binary-size(^off), len::little-64, frame::binary-size(len), _::binary>> ->
        case Block.decompress(frame) do
          {:ok, [], _} ->
            {:ok, Enum.reverse(acc), off}

          {:ok, events, usize} ->
            walk(bin, off + 8 + len, [
              %{frame: frame, events: events, uncompressed_size: usize} | acc
            ])

          {:error, _} ->
            {:ok, Enum.reverse(acc), off}
        end

      _ ->
        {:ok, Enum.reverse(acc), off}
    end
  end

  @doc """
  Rewrites a sealed segment keeping only rows `keep?` accepts, and passing
  kept rows through `transform` (the timestamp import patches `indexed_at`):
  every block stays (an emptied one as an empty frame), with its original seq
  and witnessed-at bounds, and the header keeps the segment's. Returns
  `{:ok, bin, header, changed_rows}`, or `{:unchanged, parsed}` when no row is
  dropped or altered.
  """
  def rewrite(file, parsed, keep?, transform \\ & &1) do
    {blocks, changed} =
      parsed.blocks
      |> Enum.with_index()
      |> Enum.map_reduce(0, fn {info, i}, changed ->
        {:ok, frame} = frame(file, parsed, i)
        {:ok, events, usize} = Block.decompress(frame)
        out = events |> Enum.filter(keep?) |> Enum.map(transform)
        bounds = Map.take(info, [:min_seq, :max_seq, :min_witnessed_at, :max_witnessed_at])

        altered =
          length(events) - length(out) +
            Enum.count(Enum.zip(Enum.filter(events, keep?), out), fn {a, b} -> a != b end)

        if altered == 0 do
          {%{frame: frame, events: events, uncompressed_size: usize, bounds: bounds}, changed}
        else
          {frame, usize} = Block.compress(out)

          {%{frame: frame, events: out, uncompressed_size: usize, bounds: bounds},
           changed + altered}
        end
      end)

    if changed == 0 do
      {:unchanged, parsed}
    else
      bounds = Map.take(parsed.header, [:min_seq, :max_seq, :min_witnessed_at, :max_witnessed_at])
      {bin, header} = seal(blocks, bounds: bounds)
      {:ok, bin, header, changed}
    end
  end
end
