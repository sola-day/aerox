defmodule Aerox.ATProto.Space.Repo do
  @moduledoc """
  The pure part of a permissioned repo (DESIGN §12.2, upstream `space-repo.ts`):
  a set-hash state plus the record index (`collection/rkey → cid`), an
  operation log, and the two-root CAR (commit + index) serialisation.
  Storage is elsewhere; this module only computes.
  """
  alias Aerox.ATProto.{CAR, CID, DagCBOR}
  alias Aerox.ATProto.Space.LtHash

  @type write :: %{
          action: :create | :update | :delete,
          collection: String.t(),
          rkey: String.t(),
          record: map | nil
        }
  @type prepared :: %{
          action: :create | :update | :delete,
          collection: String.t(),
          rkey: String.t(),
          record: map | nil,
          cid: CID.t() | nil,
          prev: CID.t() | nil
        }
  @type state :: %{set_hash: LtHash.t(), records: %{String.t() => {CID.t(), map}}}

  def new, do: %{set_hash: LtHash.new(), records: %{}}

  def key(collection, rkey), do: collection <> "/" <> rkey

  @doc "Recompute the set hash from the records (upstream recompute)."
  def recompute(records) do
    set_hash =
      Enum.reduce(records, LtHash.new(), fn {k, {_cid, record}}, acc ->
        [collection, rkey] = String.split(k, "/", parts: 2)
        LtHash.add(acc, LtHash.record_element(collection, rkey, record))
      end)

    %{set_hash: set_hash, records: records}
  end

  @doc "Upstream formatCommit: validate writes against the state, compute the new set hash and prepared ops."
  @spec format_commit(state, [write]) :: {:ok, [prepared], state} | {:error, term}
  def format_commit(state, writes) do
    Enum.reduce_while(writes, {:ok, [], state}, fn w, {:ok, acc, st} ->
      k = key(w.collection, w.rkey)

      case {w.action, Map.get(st.records, k)} do
        {:create, nil} ->
          cid = record_cid(w.record)

          st = %{
            st
            | set_hash:
                LtHash.add(st.set_hash, LtHash.record_element(w.collection, w.rkey, w.record)),
              records: Map.put(st.records, k, {cid, w.record})
          }

          {:cont,
           {:ok,
            [
              %{
                action: :create,
                collection: w.collection,
                rkey: w.rkey,
                record: w.record,
                cid: cid,
                prev: nil
              }
              | acc
            ], st}}

        {:create, _} ->
          {:halt, {:error, {:record_already_exists, w.collection, w.rkey}}}

        {:update, {prev_cid, prev}} ->
          cid = record_cid(w.record)

          hash =
            st.set_hash
            |> LtHash.remove(LtHash.record_element(w.collection, w.rkey, prev))
            |> LtHash.add(LtHash.record_element(w.collection, w.rkey, w.record))

          st = %{st | set_hash: hash, records: Map.put(st.records, k, {cid, w.record})}

          {:cont,
           {:ok,
            [
              %{
                action: :update,
                collection: w.collection,
                rkey: w.rkey,
                record: w.record,
                cid: cid,
                prev: prev_cid
              }
              | acc
            ], st}}

        {:delete, {prev_cid, prev}} ->
          hash = LtHash.remove(st.set_hash, LtHash.record_element(w.collection, w.rkey, prev))
          st = %{st | set_hash: hash, records: Map.delete(st.records, k)}

          {:cont,
           {:ok,
            [
              %{
                action: :delete,
                collection: w.collection,
                rkey: w.rkey,
                record: nil,
                cid: nil,
                prev: prev_cid
              }
              | acc
            ], st}}

        {_, nil} ->
          {:halt, {:error, {:record_not_found, w.collection, w.rkey}}}
      end
    end)
    |> case do
      {:ok, prepared, st} -> {:ok, Enum.reverse(prepared), st}
      e -> e
    end
  end

  @doc "The CID of a record (dag-cbor)."
  def record_cid(record), do: record |> DagCBOR.encode() |> CID.for_cbor()

  @doc "The DRISL index: a DAG-CBOR map `path → cid`."
  def index(state), do: Map.new(state.records, fn {k, {cid, _}} -> {k, cid} end)

  @doc """
  The two-root CAR of a repo (DESIGN §12.2; the alpha's `serializeRepo`):
  roots = [commit, index], then the commit block, the index block and one
  record block per index entry **in the index's canonical DAG-CBOR key order**
  (shortest key first, then bytewise) — the alpha verifier walks them in
  that order. `commit` is a `SignedCommit` (alpha, with `ver`) or a branch `Commit`.
  """
  def export_car(state, commit) do
    commit_bytes = DagCBOR.encode(commit_lex(commit))
    commit_cid = CID.for_cbor(commit_bytes)
    index_bytes = DagCBOR.encode(index(state))
    index_cid = CID.for_cbor(index_bytes)

    records =
      state.records
      |> Enum.sort_by(fn {k, _} -> {byte_size(k), k} end)
      |> Enum.map(fn {_k, {cid, record}} -> {cid, DagCBOR.encode(record)} end)

    CAR.encode([commit_cid, index_cid], [
      {commit_cid, commit_bytes},
      {index_cid, index_bytes} | records
    ])
  end

  defp commit_lex(%{ver: _} = commit), do: Aerox.ATProto.Space.SignedCommit.to_lex(commit)
  defp commit_lex(commit), do: Aerox.ATProto.Space.Commit.to_lex(commit)

  defp commit_from_lex(%{"ver" => _} = lex), do: Aerox.ATProto.Space.SignedCommit.from_lex(lex)
  defp commit_from_lex(lex), do: Aerox.ATProto.Space.Commit.from_lex(lex)

  @doc "Reads a two-root CAR back into `{commit, state}`; the set hash is recomputed and checked against the commit's hash."
  def import_car(car) do
    with {:ok, %{roots: [commit_cid, index_cid], blocks: blocks}} <- CAR.decode(car),
         bs = Map.new(blocks),
         {:ok, commit_bytes} <- Map.fetch(bs, commit_cid),
         {:ok, index_bytes} <- Map.fetch(bs, index_cid),
         {:ok, commit_lex} <- DagCBOR.decode(commit_bytes),
         {:ok, index} <- DagCBOR.decode(index_bytes) do
      records =
        Map.new(index, fn {k, %CID{} = cid} ->
          {:ok, record} = DagCBOR.decode(Map.fetch!(bs, cid))
          {k, {cid, record}}
        end)

      state = recompute(records)
      commit = commit_from_lex(commit_lex)

      if LtHash.digest(state.set_hash) == commit.hash,
        do: {:ok, commit, state},
        else: {:error, :hash_mismatch}
    else
      {:ok, %{roots: roots}} -> {:error, {:expected_two_roots, length(roots)}}
      :error -> {:error, :missing_root_block}
      e -> e
    end
  end
end
