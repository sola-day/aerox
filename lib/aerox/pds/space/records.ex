defmodule Aerox.PDS.Space.Records do
  @moduledoc """
  The permissioned repo of one account in one space (DESIGN §12.2–12.3;
  upstream `space-repo.ts`, `sql-repo-storage.ts`, `transactor.applyRepoCommit`).

  Writes: lock the `space_repo` row, load the touched records, run the pure
  `Aerox.ATProto.Space.Repo.format_commit/2` for the new LtHash state and the
  prepared ops, then persist records, oplog rows and the new state in the
  same transaction. Nothing here touches `repo_seq` (DESIGN §12.3).

  Reads: records, the oplog (`listRepoOps`), the repo state and the
  two-root CAR (`getRepo`). Commits are signed on the way out with the
  account's key (upstream `buildSignedCommit`).
  """
  import Ecto.Query
  alias Aerox.ATProto.{CID, DagCBOR}
  alias Aerox.ATProto.Space.{LtHash, SignedCommit}
  alias Aerox.ATProto.Space.Repo, as: KRepo
  alias Aerox.PDS.{Accounts, Clock, Repo}
  alias Aerox.PDS.Space.Schema.{SpaceRecord, SpaceRecordOplog, SpaceRepo}
  alias Aerox.PDS.Space.{Spaces, Uri}

  @type write :: KRepo.write()

  # ---------------------------------------------------------------- writes

  @doc """
  Applies `writes` to `did`'s repo in `space`, creating the member-side
  space row on first use. Returns the rev and the prepared writes (with CIDs).
  """
  @spec write(String.t(), String.t(), [write]) ::
          {:ok, %{rev: String.t(), writes: [KRepo.prepared()]}} | {:error, term}
  def write(did, space, writes) do
    Repo.transaction(fn ->
      Spaces.ensure_member_row(did, space)

      repo_row =
        Repo.one(
          from(r in SpaceRepo, where: r.did == ^did and r.space == ^space, lock: "FOR UPDATE")
        ) || Repo.insert!(%SpaceRepo{did: did, space: space})

      keys = Enum.map(writes, &{&1.collection, &1.rkey})

      state = %{
        set_hash: repo_row.set_hash || LtHash.new(),
        records: load_records(did, space, keys)
      }

      case KRepo.format_commit(state, writes) do
        {:error, reason} ->
          Repo.rollback(reason)

        {:ok, prepared, new_state} ->
          rev = Clock.next_tid()
          now = DateTime.utc_now()

          prepared
          |> Enum.with_index()
          |> Enum.each(fn {w, idx} -> persist(did, space, rev, now, w, idx) end)

          repo_row
          |> Ecto.Changeset.change(set_hash: new_state.set_hash, rev: rev)
          |> Repo.update!()

          %{rev: rev, writes: prepared}
      end
    end)
  end

  defp persist(did, space, rev, _now, %{action: :delete} = w, idx) do
    Repo.delete_all(
      from(r in SpaceRecord,
        where:
          r.did == ^did and r.space == ^space and r.collection == ^w.collection and
            r.rkey == ^w.rkey
      )
    )

    oplog(did, space, rev, idx, w)
  end

  defp persist(did, space, rev, now, w, idx) do
    cid = CID.to_string(w.cid)
    value = DagCBOR.encode(w.record)

    Repo.insert!(
      %SpaceRecord{
        did: did,
        space: space,
        collection: w.collection,
        rkey: w.rkey,
        cid: cid,
        value: value,
        repo_rev: rev,
        indexed_at: now
      },
      on_conflict: [set: [cid: cid, value: value, repo_rev: rev, indexed_at: now]],
      conflict_target: [:did, :space, :collection, :rkey]
    )

    oplog(did, space, rev, idx, w)
  end

  defp oplog(did, space, rev, idx, w) do
    Repo.insert!(%SpaceRecordOplog{
      did: did,
      space: space,
      rev: rev,
      idx: idx,
      action: Atom.to_string(w.action),
      collection: w.collection,
      rkey: w.rkey,
      cid: w.cid && CID.to_string(w.cid),
      prev: w.prev && CID.to_string(w.prev)
    })
  end

  defp load_records(_did, _space, []), do: %{}

  defp load_records(did, space, keys) do
    collections = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    rkeys = keys |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    from(r in SpaceRecord,
      where:
        r.did == ^did and r.space == ^space and r.collection in ^collections and
          r.rkey in ^rkeys
    )
    |> Repo.all()
    |> Enum.filter(&({&1.collection, &1.rkey} in keys))
    |> Map.new(&{KRepo.key(&1.collection, &1.rkey), {CID.parse!(&1.cid), decode(&1.value)}})
  end

  defp decode(bytes) do
    {:ok, value} = DagCBOR.decode(bytes)
    value
  end

  # ----------------------------------------------------------------- reads

  @spec get_record(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{cid: String.t(), value: map}} | {:error, :not_found}
  def get_record(did, space, collection, rkey) do
    case Repo.get_by(SpaceRecord, did: did, space: space, collection: collection, rkey: rkey) do
      nil -> {:error, :not_found}
      row -> {:ok, %{cid: row.cid, value: decode(row.value)}}
    end
  end

  @spec has_record?(String.t(), String.t(), String.t(), String.t()) :: boolean
  def has_record?(did, space, collection, rkey),
    do: match?({:ok, _}, get_record(did, space, collection, rkey))

  @doc """
  `listRecords`: `(collection, rkey)` ordered descending unless `reverse:`;
  cursor `collection/rkey` (upstream `formatListCursor`).
  """
  @spec list_records(String.t(), String.t(), keyword) ::
          %{
            records: [%{collection: String.t(), rkey: String.t(), cid: String.t()}],
            cursor: String.t() | nil
          }
  def list_records(did, space, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    reverse = Keyword.get(opts, :reverse, false)
    dir = if reverse, do: :asc, else: :desc

    q =
      from(r in SpaceRecord,
        where: r.did == ^did and r.space == ^space,
        order_by: [{^dir, r.collection}, {^dir, r.rkey}],
        limit: ^limit,
        select: %{collection: r.collection, rkey: r.rkey, cid: r.cid}
      )

    q = if c = opts[:collection], do: where(q, [r], r.collection == ^c), else: q

    q =
      case opts[:cursor] && String.split(opts[:cursor], "/", parts: 2) do
        [cc, ck] when cc != "" and ck != "" ->
          if reverse,
            do: where(q, [r], fragment("(?, ?) > (?, ?)", r.collection, r.rkey, ^cc, ^ck)),
            else: where(q, [r], fragment("(?, ?) < (?, ?)", r.collection, r.rkey, ^cc, ^ck))

        _ ->
          q
      end

    rows = Repo.all(q)
    last = List.last(rows)
    %{records: rows, cursor: last && "#{last.collection}/#{last.rkey}"}
  end

  @doc "The repo's LtHash state and rev, nil if the account never wrote to the space."
  @spec state(String.t(), String.t()) :: %{set_hash: binary | nil, rev: String.t() | nil} | nil
  def state(did, space) do
    case Repo.get_by(SpaceRepo, did: did, space: space) do
      nil -> nil
      %{set_hash: h, rev: rev} -> %{set_hash: h, rev: rev}
    end
  end

  @doc """
  `listRepoOps`: ops after `since:` (or from `cursor:`), at most `limit:`.
  Returns the signed commit only when the page reaches the head (upstream
  `getRepoOplog`), else a cursor. Values are inlined for creates/updates
  whose CID is still current unless `exclude_values:` (alpha lexicon).
  """
  @spec oplog(String.t(), String.t(), keyword) ::
          %{ops: [map], commit: map | nil, cursor: String.t() | nil}
  def oplog(did, space, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    q =
      from(o in SpaceRecordOplog,
        where: o.did == ^did and o.space == ^space,
        order_by: [asc: o.rev, asc: o.idx],
        limit: ^limit
      )

    q =
      case {opts[:cursor], opts[:since]} do
        {cursor, _} when is_binary(cursor) ->
          case String.split(cursor, ":", parts: 2) do
            [rev, idx] ->
              case Integer.parse(idx) do
                {i, ""} -> where(q, [o], fragment("(?, ?) > (?, ?)", o.rev, o.idx, ^rev, ^i))
                _ -> q
              end

            _ ->
              q
          end

        {_, since} when is_binary(since) ->
          where(q, [o], o.rev > ^since)

        _ ->
          q
      end

    rows = Repo.all(q)
    caught_up = length(rows) < limit

    current =
      if opts[:exclude_values] or rows == [] do
        %{}
      else
        keys = rows |> Enum.map(&{&1.collection, &1.rkey}) |> Enum.uniq()

        load_records(did, space, keys)
        |> Map.new(fn {k, {cid, value}} -> {k, {CID.to_string(cid), value}} end)
      end

    ops =
      Enum.map(rows, fn o ->
        base = %{rev: o.rev, collection: o.collection, rkey: o.rkey, cid: o.cid, prev: o.prev}

        case o.cid && Map.get(current, KRepo.key(o.collection, o.rkey)) do
          {cid, value} when cid == o.cid -> Map.put(base, :value, value)
          _ -> base
        end
      end)

    last = List.last(rows)

    %{
      ops: ops,
      commit: if(caught_up, do: signed_commit(did, space, :records)),
      cursor: if(not caught_up and last, do: "#{last.rev}:#{last.idx}")
    }
  end

  @doc """
  The current signed commit (upstream `buildSignedCommit`), nil before the
  first write. `scope` is `:records` (the account's repo) or `:members`
  (the owner's member list).
  """
  @spec signed_commit(String.t(), String.t(), :records | :members) :: SignedCommit.t() | nil
  def signed_commit(did, space, scope) do
    st = if scope == :records, do: state(did, space), else: Spaces.member_state(did, space)

    with %{set_hash: hash, rev: rev} when is_binary(hash) and is_binary(rev) <- st,
         {:ok, uri} <- Uri.parse(space),
         %Aerox.ATProto.Crypto.Keypair{} = keypair <- Accounts.signing_keypair(did) do
      SignedCommit.create(LtHash.digest(hash), context(uri, did, rev), keypair)
    else
      _ -> nil
    end
  end

  @doc """
  The commit context (`Aerox.ATProto.Space.SignedCommit.context/0`): the
  canonical space URI, the author (the writer, or the owner for the member
  list) and the rev.
  """
  def context(%{space: space}, author, rev), do: %{space: space, author: author, rev: rev}

  @doc "The lexicon shape of a signed commit."
  def commit_lex(nil), do: nil
  def commit_lex(commit), do: SignedCommit.to_lex(commit)

  @doc "`getRepo`: the two-root CAR of the whole repo, nil before the first write."
  @spec export_car(String.t(), String.t()) :: binary | nil
  def export_car(did, space) do
    case signed_commit(did, space, :records) do
      nil ->
        nil

      commit ->
        records =
          from(r in SpaceRecord, where: r.did == ^did and r.space == ^space)
          |> Repo.all()
          |> Map.new(&{KRepo.key(&1.collection, &1.rkey), {CID.parse!(&1.cid), decode(&1.value)}})

        state = Repo.get_by(SpaceRepo, did: did, space: space)
        KRepo.export_car(%{set_hash: state.set_hash, records: records}, commit)
    end
  end
end
