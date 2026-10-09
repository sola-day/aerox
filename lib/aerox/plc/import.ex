defmodule Aerox.PLC.Import do
  @moduledoc """
  Loads another directory's operation log — `/export` lines, as
  did-method-plc and this directory serve them — into this directory,
  verbatim. Each DID's log is replayed through
  `Operations.validate_audit_log/1` before anything is written; rows keep
  their `cid`, `createdAt` and `nullified`, and go in in the source's order,
  so `seq` follows it. Re-runnable: a DID already here must hold a prefix of
  its source log, and only the rest is added.

  Nothing is signed and nothing is submitted to any directory: the source is
  only read (DESIGN §13.5).
  """
  import Ecto.Query
  alias Aerox.PLC.{Did, Directory, Operation, Operations, Repo}

  @doc """
  The whole log of `source`: a directory's base URL (paged through
  `/export`, `page` lines at a time, at most 1000) or a file of export lines.
  """
  @spec read!(String.t(), pos_integer) :: [map]
  def read!(source, page \\ 1000)

  def read!("http" <> _ = url, page),
    do: fetch(String.trim_trailing(url, "/"), page, nil, [], MapSet.new())

  def read!(path, _page), do: path |> File.stream!() |> Enum.flat_map(&decode/1)

  # `after` is exclusive on createdAt, so ops sharing the last timestamp of a
  # page could fall between pages: each page re-reads from 1 ms earlier and
  # drops what it has already seen.
  defp fetch(url, page, after_, acc, seen) do
    query = [count: page] ++ if(after_, do: [after: after_], else: [])
    req = [params: query, decode_body: false] ++ Application.get_env(:aerox, __MODULE__, [])
    lines = Req.get!(url <> "/export", req).body |> decode_lines()
    fresh = Enum.reject(lines, &MapSet.member?(seen, key(&1)))

    cond do
      length(lines) < page ->
        Enum.reverse(acc, fresh)

      fresh == [] ->
        raise "#{url}/export: more than #{page} operations share one millisecond"

      true ->
        {:ok, last, _} = DateTime.from_iso8601(List.last(lines)["createdAt"])
        next = last |> DateTime.add(-1, :millisecond) |> DateTime.to_iso8601()
        seen = MapSet.union(seen, MapSet.new(fresh, &key/1))
        fetch(url, page, next, Enum.reverse(fresh, acc), seen)
    end
  end

  defp decode_lines(body), do: body |> String.split("\n") |> Enum.flat_map(&decode/1)

  defp decode(line) do
    case String.trim(line) do
      "" -> []
      json -> [Jason.decode!(json)]
    end
  end

  defp key(entry), do: {entry["did"], entry["cid"]}

  @doc """
  Validates every DID's log, then writes all of them, or nothing. Returns the
  number of DIDs and of operations added, or the DIDs that failed and why.
  """
  @spec run([map]) ::
          {:ok, %{dids: non_neg_integer, added: non_neg_integer}}
          | {:error, [{String.t(), term}]}
  def run(entries) do
    logs = Enum.group_by(entries, & &1["did"])

    case for({did, log} <- logs, reason = check(did, log), do: {did, reason}) do
      [] -> {:ok, %{dids: map_size(logs), added: insert(entries)}}
      failed -> {:error, failed}
    end
  end

  defp check(did, log) do
    here = Enum.map(Directory.audit_log(did), & &1["cid"])

    cond do
      not Operations.valid_plc_did?(did) ->
        :invalid_did

      here != log |> Enum.take(length(here)) |> Enum.map(& &1["cid"]) ->
        :differs_from_existing_log

      true ->
        with :ok <- Operations.validate_audit_log(log), do: nil
    end
  end

  defp insert(entries) do
    {:ok, added} =
      Repo.transaction(fn ->
        dids = entries |> Enum.map(& &1["did"]) |> Enum.uniq() |> Enum.map(&%{did: &1})
        Repo.insert_all(Did, dids, on_conflict: :nothing)
        existing = MapSet.new(Repo.all(from(o in Operation, select: {o.did, o.cid})))
        rows = for e <- entries, not MapSet.member?(existing, key(e)), do: row(e)
        rows |> Enum.chunk_every(1000) |> Enum.each(&Repo.insert_all(Operation, &1))
        # a later op may have nullified one that was already here
        for e <- entries, e["nullified"], MapSet.member?(existing, key(e)) do
          Repo.update_all(where(Operation, did: ^e["did"], cid: ^e["cid"]),
            set: [nullified: true]
          )
        end

        length(rows)
      end)

    added
  end

  defp row(entry) do
    {:ok, at, _} = DateTime.from_iso8601(entry["createdAt"])

    %{
      did: entry["did"],
      cid: entry["cid"],
      operation: entry["operation"],
      nullified: entry["nullified"],
      created_at: %{at | microsecond: {elem(at.microsecond, 0), 6}}
    }
  end
end
