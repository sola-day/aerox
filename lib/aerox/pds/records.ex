defmodule Aerox.PDS.Records do
  @moduledoc """
  The PDS write path (DESIGN §3.6, §4.2, §21.3) and record reads.

  `process_writes/3` runs in one transaction: lock the account's `repo_root`
  row `FOR UPDATE` (the per-account serialisation point — a row lock, not a
  process), load the repo through the Postgres blockstore, let the kernel
  format the commit, persist blocks/root/index/backlinks/blob references,
  then hand the commit to the sequencer, which broadcasts after its own
  commit. Two writes to one DID serialise on the lock; writes to different
  DIDs interleave.
  """
  import Ecto.Query
  alias Aerox.ATProto.{CID, Data, DagCBOR, Syntax}
  alias Aerox.ATProto.Blockstore, as: KBlockstore
  alias Aerox.ATProto.Repo, as: KRepo
  alias Aerox.PDS.{Blockstore, Clock, Repo, Sequencer}
  alias Aerox.PDS.Schema.{Backlink, Blob, Record, RecordBlob, RepoBlock, RepoRoot}
  alias Aerox.PDS.Records.Prepare

  @type write :: Prepare.prepared()

  defmodule Error do
    defexception [:kind, :message, :cid]
  end

  # ---------------------------------------------------------------- write

  @doc """
  Applies prepared writes as one commit. Options: `swap_commit:` (a CID the
  current root must equal), `sequence:` (default true), `keypair:` (default:
  the account's signing key), `rev:` (default: from the clock).
  Returns `{:ok, commit_data}` with `:seq` when sequenced, or
  `{:error, %Error{kind: :invalid_swap | :not_found | ...}}`.
  """
  @spec process_writes(String.t(), [write], keyword) :: {:ok, map} | {:error, Error.t() | term}
  def process_writes(did, writes, opts \\ []) do
    if length(writes) > 200 do
      {:error, %Error{kind: :invalid_request, message: "Too many writes. Max: 200"}}
    else
      Repo.transaction(fn -> do_process_writes(did, writes, opts) end, timeout: 60_000)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, %Error{} = e} -> {:error, e}
        {:error, other} -> {:error, other}
      end
    end
  end

  defp do_process_writes(did, writes, opts) do
    root =
      Repo.one(from(r in RepoRoot, where: r.did == ^did, lock: "FOR UPDATE")) ||
        Repo.rollback(%Error{kind: :not_found, message: "No repo root found for #{did}"})

    case Keyword.get(opts, :swap_commit) do
      nil ->
        :ok

      %CID{} = swap ->
        if CID.to_string(swap) == root.cid,
          do: :ok,
          else:
            Repo.rollback(%Error{
              kind: :invalid_swap,
              message: "Commit was at #{root.cid}",
              cid: root.cid
            })
    end

    keypair = Keyword.get(opts, :keypair) || signing_keypair!(did)
    rev = Keyword.get(opts, :rev) || Clock.next_tid_after(root.rev)
    bs = Blockstore.new(did, rev)
    {:ok, repo} = KRepo.load(bs, CID.parse!(root.cid))

    # current record state for swap checks and op prevs
    current = current_cids(did, Enum.map(writes, & &1.uri))
    Enum.each(writes, &check_record_swap(&1, Map.get(current, &1.uri)))

    kernel_writes =
      Enum.map(writes, fn
        %{action: :create} = w -> {:create, w.collection, w.rkey, w.record}
        %{action: :update} = w -> {:update, w.collection, w.rkey, w.record}
        %{action: :delete} = w -> {:delete, w.collection, w.rkey}
      end)

    commit =
      case KRepo.format_commit(bs, repo, kernel_writes, keypair, rev) do
        {:ok, commit} ->
          commit

        {:error, {:record_not_found, key}} ->
          Repo.rollback(%Error{kind: :not_found, message: "Could not find record: #{key}"})

        {:error, reason} ->
          Repo.rollback(%Error{kind: :invalid_request, message: inspect(reason)})
      end

    now = DateTime.utc_now()
    # blocks that are being removed but are still referenced by another record stay
    keep =
      referenced_elsewhere(did, MapSet.to_list(commit.removed_cids), Enum.map(writes, & &1.uri))

    removed = MapSet.difference(commit.removed_cids, MapSet.new(keep))

    {:ok, _} = KBlockstore.put_many(bs, Map.to_list(commit.new_blocks))
    Blockstore.delete_many(did, MapSet.to_list(removed))

    Repo.update_all(from(r in RepoRoot, where: r.did == ^did),
      set: [cid: CID.to_string(commit.cid), rev: rev, indexed_at: now]
    )

    index_writes(did, writes, rev, now)

    commit = %{commit | removed_cids: removed}

    if Keyword.get(opts, :sequence, true) do
      {:ok, [seq]} = Sequencer.sequence_commit(did, commit)
      Map.put(commit, :seq, seq)
    else
      commit
    end
  end

  defp check_record_swap(%{swap_cid: :unset}, _current), do: :ok

  defp check_record_swap(%{action: action, swap_cid: swap}, current) do
    current_str = current && CID.to_string(current)
    swap_str = swap && CID.to_string(swap)

    bad =
      (action == :create and swap != nil) or
        (action == :update and swap == nil) or
        (action == :delete and swap == nil) or
        ((current != nil or swap != nil) and current_str != swap_str)

    if bad,
      do:
        Repo.rollback(%Error{
          kind: :invalid_swap,
          message: "Record was at #{current_str || "null"}",
          cid: current_str
        })
  end

  defp current_cids(did, uris) do
    from(r in Record, where: r.did == ^did and r.uri in ^uris, select: {r.uri, r.cid})
    |> Repo.all()
    |> Map.new(fn {uri, cid} -> {uri, CID.parse!(cid)} end)
  end

  defp referenced_elsewhere(_did, [], _uris), do: []

  defp referenced_elsewhere(did, cids, uris) do
    strs = Enum.map(cids, &CID.to_string/1)

    from(r in Record,
      where: r.did == ^did and r.cid in ^strs and r.uri not in ^uris,
      select: r.cid
    )
    |> Repo.all()
    |> Enum.map(&CID.parse!/1)
  end

  defp index_writes(did, writes, rev, now) do
    for write <- writes do
      case write do
        %{action: :delete, uri: uri} ->
          Repo.delete_all(from(r in Record, where: r.did == ^did and r.uri == ^uri))
          Repo.delete_all(from(b in Backlink, where: b.did == ^did and b.uri == ^uri))
          dereference_blobs(did, uri, [])

        %{uri: uri, cid: cid, collection: collection, rkey: rkey, record: record, blobs: blobs} ->
          Repo.insert_all(
            Record,
            [
              %{
                did: did,
                collection: collection,
                rkey: rkey,
                uri: uri,
                cid: CID.to_string(cid),
                rev: rev,
                indexed_at: now
              }
            ],
            on_conflict: {:replace, [:cid, :rev, :indexed_at]},
            conflict_target: [:did, :collection, :rkey]
          )

          Repo.delete_all(from(b in Backlink, where: b.did == ^did and b.uri == ^uri))
          add_backlinks(did, uri, record)
          new_cids = Enum.map(blobs, &CID.to_string(&1["ref"]))
          if write.action == :update, do: dereference_blobs(did, uri, new_cids)
          associate_blobs(did, uri, new_cids)
      end
    end
  end

  @doc "Upstream `getBacklinks`: follows/blocks link to a DID subject; likes/reposts to a record URI. Returns `[{path, link_to}]`."
  @spec backlinks(String.t(), map) :: [{String.t(), String.t()}]
  def backlinks(_uri, record) do
    case record["$type"] do
      t when t in ["app.bsky.graph.follow", "app.bsky.graph.block"] ->
        case record["subject"] do
          s when is_binary(s) -> if Syntax.valid_did?(s), do: [{"subject", s}], else: []
          _ -> []
        end

      t when t in ["app.bsky.feed.like", "app.bsky.feed.repost"] ->
        case get_in(record, ["subject", "uri"]) do
          s when is_binary(s) -> if Syntax.valid_at_uri?(s), do: [{"subject.uri", s}], else: []
          _ -> []
        end

      _ ->
        []
    end
  end

  defp add_backlinks(did, uri, record) do
    rows =
      for {path, link_to} <- backlinks(uri, record),
          do: %{did: did, uri: uri, path: path, link_to: link_to}

    if rows != [], do: Repo.insert_all(Backlink, rows, on_conflict: :nothing)
  end

  @doc "Records in `collection` that already link to the same subject (upstream `getBacklinkConflicts`), as URIs."
  @spec backlink_conflicts(String.t(), String.t(), String.t(), map) :: [String.t()]
  def backlink_conflicts(did, uri, collection, record) do
    Enum.flat_map(backlinks(uri, record), fn {path, link_to} ->
      from(r in Record,
        join: b in Backlink,
        on: b.did == r.did and b.uri == r.uri,
        where:
          r.did == ^did and r.collection == ^collection and b.path == ^path and
            b.link_to == ^link_to,
        select: r.uri
      )
      |> Repo.all()
    end)
  end

  # record_blob rows: the lifecycle mechanism of DESIGN §4.4.
  defp associate_blobs(_did, _uri, []), do: :ok

  defp associate_blobs(did, uri, cids) do
    Repo.insert_all(RecordBlob, Enum.map(cids, &%{did: did, blob_cid: &1, record_uri: uri}),
      on_conflict: :nothing
    )
  end

  # Drop this record's blob references; blob rows nobody references any more
  # are deleted (the store object is reaped later — DESIGN §4.4 "row first").
  defp dereference_blobs(did, uri, keep_cids) do
    {_, old} =
      Repo.delete_all(
        from(rb in RecordBlob,
          where: rb.did == ^did and rb.record_uri == ^uri,
          select: rb.blob_cid
        )
      )

    candidates = Enum.reject(old || [], &(&1 in keep_cids))

    if candidates != [] do
      still =
        from(rb in RecordBlob,
          where: rb.did == ^did and rb.blob_cid in ^candidates,
          select: rb.blob_cid
        )
        |> Repo.all()

      gone = candidates -- still
      if gone != [], do: Repo.delete_all(from(b in Blob, where: b.did == ^did and b.cid in ^gone))
    end

    :ok
  end

  defp signing_keypair!(did) do
    case Repo.one(from(a in Aerox.PDS.Schema.Actor, where: a.did == ^did, select: a.signing_key)) do
      nil -> Repo.rollback(%Error{kind: :not_found, message: "Account not found: #{did}"})
      key -> Aerox.ATProto.Crypto.from_private(:k256, key)
    end
  end

  @doc "Creates the empty repo for a new account (the init commit), inside the caller's transaction or its own."
  @spec create_repo(String.t(), Aerox.ATProto.Crypto.Keypair.t(), keyword) ::
          {:ok, map} | {:error, term}
  def create_repo(did, keypair, opts \\ []) do
    rev = Keyword.get(opts, :rev) || Clock.next_tid()
    bs = Blockstore.new(did, rev)

    with {:ok, commit} <- KRepo.format_init_commit(bs, did, keypair, [], rev) do
      now = DateTime.utc_now()
      {:ok, _} = KBlockstore.put_many(bs, Map.to_list(commit.new_blocks))
      Repo.insert!(%RepoRoot{did: did, cid: CID.to_string(commit.cid), rev: rev, indexed_at: now})
      {:ok, commit}
    end
  end

  # ----------------------------------------------------------------- read

  @doc "The current root, or nil."
  @spec root(String.t()) :: %{cid: CID.t(), rev: String.t()} | nil
  def root(did) do
    case Repo.one(from(r in RepoRoot, where: r.did == ^did)) do
      nil -> nil
      r -> %{cid: CID.parse!(r.cid), rev: r.rev, indexed_at: r.indexed_at}
    end
  end

  @doc "A record with its value; `cid:` pins a version; taken-down records are hidden unless `include_taken_down:`."
  @spec get_record(String.t(), String.t(), String.t(), keyword) ::
          {:ok, map} | {:error, :not_found}
  def get_record(did, collection, rkey, opts \\ []) do
    q =
      from(r in Record,
        join: b in RepoBlock,
        on: b.did == r.did and b.cid == r.cid,
        where: r.did == ^did and r.collection == ^collection and r.rkey == ^rkey,
        select: {r, b.content}
      )

    q = if cid = opts[:cid], do: where(q, [r], r.cid == ^cid), else: q
    q = if opts[:include_taken_down], do: q, else: where(q, [r], is_nil(r.takedown_ref))

    case Repo.one(q) do
      nil ->
        {:error, :not_found}

      {r, content} ->
        {:ok,
         %{
           uri: r.uri,
           cid: r.cid,
           value: DagCBOR.decode!(content),
           indexed_at: r.indexed_at,
           takedown_ref: r.takedown_ref
         }}
    end
  end

  @doc "Upstream `listRecordsForCollection`: by rkey, descending unless `reverse:`, with `cursor:`/`rkey_start:`/`rkey_end:`."
  @spec list_records(String.t(), String.t(), keyword) :: [map]
  def list_records(did, collection, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    reverse = Keyword.get(opts, :reverse, false)

    q =
      from(r in Record,
        join: b in RepoBlock,
        on: b.did == r.did and b.cid == r.cid,
        where: r.did == ^did and r.collection == ^collection and is_nil(r.takedown_ref),
        limit: ^limit,
        select: {r, b.content}
      )

    q = if reverse, do: order_by(q, [r], asc: r.rkey), else: order_by(q, [r], desc: r.rkey)

    q =
      case {opts[:cursor], reverse} do
        {nil, _} ->
          q
          |> maybe_where(opts[:rkey_start], fn q, v -> where(q, [r], r.rkey > ^v) end)
          |> maybe_where(opts[:rkey_end], fn q, v -> where(q, [r], r.rkey < ^v) end)

        {c, true} ->
          where(q, [r], r.rkey > ^c)

        {c, false} ->
          where(q, [r], r.rkey < ^c)
      end

    q
    |> Repo.all()
    |> Enum.map(fn {r, content} ->
      %{uri: r.uri, cid: r.cid, value: DagCBOR.decode!(content), rkey: r.rkey}
    end)
  end

  defp maybe_where(q, nil, _), do: q
  defp maybe_where(q, v, fun), do: fun.(q, v)

  @spec list_collections(String.t()) :: [String.t()]
  def list_collections(did),
    do:
      Repo.all(
        from(r in Record,
          where: r.did == ^did,
          group_by: r.collection,
          select: r.collection,
          order_by: r.collection
        )
      )

  @spec record_count(String.t()) :: non_neg_integer
  def record_count(did), do: Repo.aggregate(from(r in Record, where: r.did == ^did), :count)

  @doc "The record value as JSON-ready term."
  def to_json(value), do: Data.to_json(value)

  @doc "Sets or clears the takedown ref on a record (admin/moderation)."
  def update_record_takedown(did, uri, ref) do
    Repo.update_all(from(r in Record, where: r.did == ^did and r.uri == ^uri),
      set: [takedown_ref: ref]
    )

    :ok
  end
end
