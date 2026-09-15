defmodule Aerox.ATProto.Repo do
  @moduledoc """
  Commit production **and** verification (DESIGN §3.6), pure. A repo is
  `{commit cid, commit, MST}` over a blockstore. Writing records is
  `format_commit/5`: apply the ops to the MST, diff, sign, and return the
  new blocks, removed CIDs, ops with `prev` CIDs and `prev_data` — exactly
  what the sequencer emits. The PDS only persists and broadcasts.

  Verification covers other people's commits too: `verify_commit_message/2`
  is indigo's inductive check for sync v1.1 — with only the blocks a
  firehose commit carries, invert the ops on the partial tree and require
  the result to equal `prevData` — plus the signature; `verify_diff/6` is
  upstream's `verifyDiff` for full-repo and diff CARs.

  Only repo v3 (`version: 3`, `prev: null`) is produced; v2 commits are
  accepted on read and upgraded, as upstream's `ensureV3Commit` does.
  """
  alias Aerox.ATProto.{Blockstore, Bytes, CAR, CID, Crypto, DagCBOR, MST, Syntax}
  alias Aerox.ATProto.Blockstore.{Layered, Memory}

  @type commit :: %{required(String.t()) => term}
  @type write ::
          {:create, collection :: String.t(), rkey :: String.t(), record :: map}
          | {:update, String.t(), String.t(), map}
          | {:delete, String.t(), String.t()}

  @typedoc "A repo op as it appears on the firehose."
  @type op :: %{
          action: :create | :update | :delete,
          path: String.t(),
          cid: CID.t() | nil,
          prev: CID.t() | nil
        }

  @type t :: %{cid: CID.t(), commit: commit, data: MST.t()}

  @type commit_data :: %{
          cid: CID.t(),
          rev: String.t(),
          since: String.t() | nil,
          prev: CID.t() | nil,
          prev_data: CID.t() | nil,
          data: CID.t(),
          new_blocks: %{CID.t() => binary},
          relevant_blocks: %{CID.t() => binary},
          removed_cids: MapSet.t(CID.t()),
          ops: [op],
          mst: MST.t()
        }

  @max_ops 200

  # ---------------------------------------------------------------- keys

  @spec data_key(String.t(), String.t()) :: String.t()
  def data_key(collection, rkey), do: collection <> "/" <> rkey

  @spec parse_data_key(String.t()) :: {:ok, String.t(), String.t()} | :error
  def parse_data_key(key) do
    case String.split(key, "/") do
      [collection, rkey] -> {:ok, collection, rkey}
      _ -> :error
    end
  end

  # -------------------------------------------------------------- commits

  @doc "Signs an unsigned commit map, returning the commit with `sig`."
  @spec sign_commit(map, Crypto.Keypair.t()) :: commit
  def sign_commit(unsigned, %Crypto.Keypair{} = keypair) do
    unsigned = Map.delete(unsigned, "sig")
    Map.put(unsigned, "sig", Bytes.new(Crypto.sign(keypair, DagCBOR.encode(unsigned))))
  end

  @doc "Verifies a commit's signature against a `did:key`."
  @spec verify_commit_sig(commit, String.t()) :: boolean
  def verify_commit_sig(%{"sig" => %Bytes{data: sig}} = commit, did_key) do
    Crypto.verify_did_sig(did_key, DagCBOR.encode(Map.delete(commit, "sig")), sig)
  end

  def verify_commit_sig(_, _), do: false

  @doc "Structural check of a commit map; v2 commits are upgraded to v3."
  @spec ensure_commit(term) :: {:ok, commit} | {:error, term}
  def ensure_commit(
        %{"did" => did, "version" => 3, "data" => %CID{}, "rev" => rev, "sig" => %Bytes{}} = c
      )
      when is_binary(did) and is_binary(rev) do
    if Map.get(c, "prev", nil) in [nil] or match?(%CID{}, c["prev"]),
      do: {:ok, Map.put_new(c, "prev", nil)},
      else: {:error, :invalid_prev}
  end

  def ensure_commit(%{"did" => did, "version" => 2, "data" => %CID{}, "sig" => %Bytes{}} = c)
      when is_binary(did) do
    {:ok,
     c |> Map.put("version", 3) |> Map.put_new("rev", "2222222222222") |> Map.put_new("prev", nil)}
  end

  def ensure_commit(_), do: {:error, :invalid_commit}

  # ------------------------------------------------------------------ load

  @doc "Loads a repo from its commit CID."
  @spec load(Blockstore.t(), CID.t()) :: {:ok, t} | {:error, term}
  def load(bs, commit_cid) do
    with {:ok, value} <- Blockstore.get_value(bs, commit_cid),
         {:ok, commit} <- ensure_commit(value) do
      {:ok, %{cid: commit_cid, commit: commit, data: MST.load(commit["data"])}}
    end
  end

  @doc "A record by collection and rkey."
  @spec get_record(Blockstore.t(), t, String.t(), String.t()) ::
          {:ok, CID.t(), map} | {:error, :not_found | term}
  def get_record(bs, repo, collection, rkey) do
    with {:ok, %CID{} = cid} <- record_cid(bs, repo, collection, rkey),
         {:ok, value} <- Blockstore.get_value(bs, cid) do
      {:ok, cid, value}
    else
      {:ok, nil} -> {:error, :not_found}
      other -> other
    end
  end

  @spec record_cid(Blockstore.t(), t, String.t(), String.t()) ::
          {:ok, CID.t() | nil} | {:error, term}
  def record_cid(bs, repo, collection, rkey),
    do: MST.get(bs, repo.data, data_key(collection, rkey))

  # ---------------------------------------------------------------- write

  @doc """
  The initial commit of a new repo: an empty (or seeded) MST, signed.
  `rev` defaults to a caller-supplied TID (the kernel has no clock).
  """
  @spec format_init_commit(Blockstore.t(), String.t(), Crypto.Keypair.t(), [write], String.t()) ::
          {:ok, commit_data} | {:error, term}
  def format_init_commit(bs, did, keypair, writes \\ [], rev) do
    with {:ok, mst, leaves, ops} <- apply_writes(bs, MST.empty(), writes),
         {:ok, diff} <- MST.diff(bs, nil, mst),
         {:ok, data_cid, mst} <- MST.root(bs, mst) do
      commit =
        sign_commit(
          %{"did" => did, "version" => 3, "rev" => rev, "prev" => nil, "data" => data_cid},
          keypair
        )

      commit_bytes = DagCBOR.encode(commit)
      commit_cid = CID.for_cbor(commit_bytes)

      new_blocks =
        diff.new_mst_blocks
        |> Map.merge(Map.take(leaves, MapSet.to_list(diff.new_leaf_cids)))
        |> Map.put(commit_cid, commit_bytes)

      {:ok,
       %{
         cid: commit_cid,
         rev: rev,
         since: nil,
         prev: nil,
         prev_data: nil,
         data: data_cid,
         new_blocks: new_blocks,
         relevant_blocks: new_blocks,
         removed_cids: diff.removed_cids,
         ops: ops,
         mst: mst,
         commit: commit
       }}
    end
  end

  @doc """
  Applies writes to a loaded repo and produces the next signed commit with
  everything the sequencer needs (upstream `formatCommit` plus the PDS
  transactor's `ops` and `prevData`). `rev` must be newer than the current
  one (the caller's clock decides).
  """
  @spec format_commit(Blockstore.t(), t, [write], Crypto.Keypair.t(), String.t()) ::
          {:ok, commit_data} | {:error, term}
  def format_commit(
        bs,
        %{cid: prev_cid, commit: prev_commit, data: prev_mst} = _repo,
        writes,
        keypair,
        rev
      ) do
    cond do
      length(writes) > @max_ops -> {:error, {:too_many_writes, @max_ops}}
      rev <= prev_commit["rev"] -> {:error, {:rev_not_newer, rev, prev_commit["rev"]}}
      true -> do_format_commit(bs, prev_cid, prev_commit, prev_mst, writes, keypair, rev)
    end
  end

  defp do_format_commit(bs, prev_cid, prev_commit, prev_mst, writes, keypair, rev) do
    with {:ok, mst, leaves, ops} <- apply_writes(bs, prev_mst, writes),
         {:ok, data_cid, mst} <- MST.root(bs, mst),
         {:ok, diff} <- MST.diff(bs, prev_mst, mst),
         {:ok, proofs} <- covering_proofs(bs, mst, writes) do
      commit =
        sign_commit(
          %{
            "did" => prev_commit["did"],
            "version" => 3,
            "rev" => rev,
            "prev" => nil,
            "data" => data_cid
          },
          keypair
        )

      commit_bytes = DagCBOR.encode(commit)
      commit_cid = CID.for_cbor(commit_bytes)

      added_leaves = Map.take(leaves, MapSet.to_list(diff.new_leaf_cids))
      missing = MapSet.difference(diff.new_leaf_cids, MapSet.new(Map.keys(added_leaves)))

      if MapSet.size(missing) > 0 do
        {:error, {:missing_leaf_blocks, MapSet.to_list(missing)}}
      else
        new_blocks =
          diff.new_mst_blocks |> Map.merge(added_leaves) |> Map.put(commit_cid, commit_bytes)

        relevant = proofs |> Map.merge(added_leaves) |> Map.put(commit_cid, commit_bytes)
        removed = MapSet.put(diff.removed_cids, prev_cid)

        {:ok,
         %{
           cid: commit_cid,
           rev: rev,
           since: prev_commit["rev"],
           prev: prev_cid,
           prev_data: prev_commit["data"],
           data: data_cid,
           new_blocks: new_blocks,
           relevant_blocks: relevant,
           removed_cids: removed,
           ops: ops,
           mst: mst,
           commit: commit
         }}
      end
    end
  end

  # Applies writes in order. Returns the tree, the encoded leaf blocks by CID
  # and the firehose ops (with `prev` for update/delete).
  defp apply_writes(bs, mst, writes) do
    Enum.reduce_while(writes, {:ok, mst, %{}, []}, fn write, {:ok, mst, leaves, ops} ->
      case apply_write(bs, mst, write) do
        {:ok, mst, leaves2, op} -> {:cont, {:ok, mst, Map.merge(leaves, leaves2), [op | ops]}}
        {:error, _} = e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, mst, leaves, ops} -> {:ok, mst, leaves, Enum.reverse(ops)}
      e -> e
    end
  end

  defp apply_write(bs, mst, {:create, collection, rkey, record}) do
    key = data_key(collection, rkey)

    with :ok <- check_key(collection, rkey),
         {bytes, cid} <- encode_record(record),
         {:ok, mst} <- MST.add(bs, mst, key, cid) do
      {:ok, mst, %{cid => bytes}, %{action: :create, path: key, cid: cid, prev: nil}}
    end
  end

  defp apply_write(bs, mst, {:update, collection, rkey, record}) do
    key = data_key(collection, rkey)

    with :ok <- check_key(collection, rkey),
         {bytes, cid} <- encode_record(record),
         {:ok, %CID{} = prev} <- get_existing(bs, mst, key),
         {:ok, mst} <- MST.update(bs, mst, key, cid) do
      {:ok, mst, %{cid => bytes}, %{action: :update, path: key, cid: cid, prev: prev}}
    end
  end

  defp apply_write(bs, mst, {:delete, collection, rkey}) do
    key = data_key(collection, rkey)

    with :ok <- check_key(collection, rkey),
         {:ok, %CID{} = prev} <- get_existing(bs, mst, key),
         {:ok, mst} <- MST.delete(bs, mst, key) do
      {:ok, mst, %{}, %{action: :delete, path: key, cid: nil, prev: prev}}
    end
  end

  defp get_existing(bs, mst, key) do
    case MST.get(bs, mst, key) do
      {:ok, nil} -> {:error, {:record_not_found, key}}
      other -> other
    end
  end

  defp check_key(collection, rkey) do
    cond do
      not Syntax.valid_nsid?(collection) -> {:error, {:invalid_collection, collection}}
      not Syntax.valid_record_key?(rkey) -> {:error, {:invalid_rkey, rkey}}
      true -> :ok
    end
  end

  defp encode_record(record) when is_map(record) do
    bytes = DagCBOR.encode(record)
    {bytes, CID.for_cbor(bytes)}
  end

  defp covering_proofs(bs, mst, writes) do
    Enum.reduce_while(writes, {:ok, %{}}, fn write, {:ok, acc} ->
      key = data_key(elem(write, 1), elem(write, 2))

      case MST.covering_proof(bs, mst, key) do
        {:ok, proof} -> {:cont, {:ok, Map.merge(acc, proof)}}
        e -> {:halt, e}
      end
    end)
  end

  @doc "Re-signs the current data root with a new rev and no data change (key rotation, `#sync` events)."
  @spec format_resign_commit(t, Crypto.Keypair.t(), String.t()) :: commit_data
  def format_resign_commit(%{cid: prev_cid, commit: prev_commit, data: mst}, keypair, rev) do
    commit =
      sign_commit(
        %{
          "did" => prev_commit["did"],
          "version" => 3,
          "rev" => rev,
          "prev" => nil,
          "data" => prev_commit["data"]
        },
        keypair
      )

    bytes = DagCBOR.encode(commit)
    cid = CID.for_cbor(bytes)

    %{
      cid: cid,
      rev: rev,
      since: prev_commit["rev"],
      prev: prev_cid,
      prev_data: prev_commit["data"],
      data: prev_commit["data"],
      new_blocks: %{cid => bytes},
      relevant_blocks: %{cid => bytes},
      removed_cids: MapSet.new([prev_cid]),
      ops: [],
      mst: mst,
      commit: commit
    }
  end

  # ---------------------------------------------------------------- export

  @doc """
  Every block of the repo in the Repository spec's streamable CAR order: the
  commit, then the MST pre-order with each record after the node that lists it
  (`MST.streamable_blocks/2`).
  """
  @spec full_repo_blocks(Blockstore.t(), CID.t()) :: {:ok, [Blockstore.block()]} | {:error, term}
  def full_repo_blocks(bs, commit_cid) do
    with {:ok, blocks} <- repo_block_stream(bs, commit_cid) do
      {:ok, Enum.to_list(blocks)}
    end
  rescue
    e in MST.MissingBlock -> {:error, {:missing_block, e.cid}}
  end

  @doc "The full repo as a CAR binary."
  @spec export_car(Blockstore.t(), CID.t()) :: {:ok, binary} | {:error, term}
  def export_car(bs, commit_cid) do
    with {:ok, blocks} <- full_repo_blocks(bs, commit_cid),
         do: {:ok, CAR.encode(commit_cid, blocks)}
  end

  @doc """
  The full repo as a lazy stream of CAR chunks (iodata), for `getRepo` on
  repositories too large to build in memory. The commit is read up front, so a
  missing repo is an error before anything is sent; a block missing further
  in raises `MST.MissingBlock` while the stream is consumed.
  """
  @spec stream_car(Blockstore.t(), CID.t()) :: {:ok, Enumerable.t()} | {:error, term}
  def stream_car(bs, commit_cid) do
    with {:ok, blocks} <- repo_block_stream(bs, commit_cid),
         do: {:ok, CAR.encode_stream(commit_cid, blocks)}
  end

  defp repo_block_stream(bs, commit_cid) do
    with {:ok, commit_bytes} <- fetch(bs, commit_cid),
         {:ok, repo} <- load(bs, commit_cid) do
      {:ok, Stream.concat([{commit_cid, commit_bytes}], MST.streamable_blocks(bs, repo.data))}
    end
  end

  @doc "The blocks proving one record: commit, the MST path, and the record (`com.atproto.sync.getRecord`)."
  @spec record_proof_blocks(Blockstore.t(), CID.t(), String.t(), String.t()) ::
          {:ok, [Blockstore.block()]} | {:error, term}
  def record_proof_blocks(bs, commit_cid, collection, rkey) do
    with {:ok, commit_bytes} <- fetch(bs, commit_cid),
         {:ok, repo} <- load(bs, commit_cid),
         {:ok, cids} <- MST.cids_for_path(bs, repo.data, data_key(collection, rkey)),
         {:ok, blocks} <- fetch_all(bs, cids) do
      {:ok, [{commit_cid, commit_bytes} | blocks]}
    end
  end

  defp fetch(bs, cid) do
    case Blockstore.get(bs, cid) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> {:error, {:missing_block, cid}}
    end
  end

  defp fetch_all(bs, cids) do
    found = Blockstore.get_many(bs, cids)

    case Enum.reject(cids, &Map.has_key?(found, &1)) do
      [] -> {:ok, Enum.map(cids, &{&1, found[&1]})}
      missing -> {:error, {:missing_blocks, missing}}
    end
  end

  # ---------------------------------------------------------------- verify

  @doc """
  Upstream `verifyRepo` over a CAR: loads the commit at the root, checks
  `did` and the signature when given, walks the whole tree and returns the
  creates (every record) plus the commit. The MST root must recompute from
  the blocks — the DESIGN §3.5 step-1 proof.
  """
  @spec verify_repo_car(binary, keyword) ::
          {:ok, %{commit: commit, cid: CID.t(), records: [op], blockstore: Blockstore.t()}}
          | {:error, term}
  def verify_repo_car(car, opts \\ []) do
    with {:ok, root, blocks} <- CAR.decode_with_root(car),
         bs = Memory.new(blocks),
         {:ok, result} <- verify_diff(nil, bs, root, opts) do
      {:ok, Map.put(result, :blockstore, bs)}
    end
  end

  @doc """
  Upstream `verifyDiff`: given the previous repo (or nil) and staged blocks
  with the new root, verify the commit and return the writes it implies.
  Options: `did:`, `signing_key:` (a `did:key`), `ensure_leaves:` (default true).
  """
  @spec verify_diff(t | nil, Blockstore.t(), CID.t(), keyword) ::
          {:ok,
           %{
             commit: commit,
             cid: CID.t(),
             records: [op],
             diff: MST.Diff.t(),
             new_blocks: %{CID.t() => binary}
           }}
          | {:error, term}
  def verify_diff(prev_repo, staged, root, opts \\ []) do
    bs = if prev_repo, do: Layered.new(staged, opts[:base] || staged), else: staged

    with {:ok, updated} <- load(bs, root),
         :ok <- check_did(updated.commit, opts[:did]),
         :ok <- check_sig(updated.commit, opts[:signing_key]),
         :ok <- MST.verify_structure(bs, updated.data),
         {:ok, diff} <- MST.diff(bs, prev_repo && prev_repo.data, updated.data),
         :ok <- ensure_leaves(staged, diff, Keyword.get(opts, :ensure_leaves, true)) do
      new_blocks =
        Map.merge(
          diff.new_mst_blocks,
          Blockstore.get_many(staged, MapSet.to_list(diff.new_leaf_cids))
        )

      {:ok,
       %{
         commit: updated.commit,
         cid: root,
         records: diff_to_ops(diff),
         diff: diff,
         new_blocks: new_blocks
       }}
    end
  end

  defp check_did(_commit, nil), do: :ok
  defp check_did(%{"did" => did}, did), do: :ok
  defp check_did(%{"did" => did}, _), do: {:error, {:invalid_repo_did, did}}

  defp check_sig(_commit, nil), do: :ok

  defp check_sig(commit, did_key),
    do: if(verify_commit_sig(commit, did_key), do: :ok, else: {:error, :invalid_signature})

  defp ensure_leaves(_staged, _diff, false), do: :ok

  defp ensure_leaves(staged, diff, true) do
    cids = MapSet.to_list(diff.new_leaf_cids)
    found = Blockstore.get_many(staged, cids)

    case Enum.reject(cids, &Map.has_key?(found, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_leaf_blocks, missing}}
    end
  end

  @doc "A diff as firehose-shaped ops."
  @spec diff_to_ops(MST.Diff.t()) :: [op]
  def diff_to_ops(%MST.Diff{} = diff) do
    Enum.map(diff.adds, fn {k, cid} -> %{action: :create, path: k, cid: cid, prev: nil} end) ++
      Enum.map(diff.updates, fn {k, {prev, cid}} ->
        %{action: :update, path: k, cid: cid, prev: prev}
      end) ++
      Enum.map(diff.deletes, fn {k, cid} -> %{action: :delete, path: k, cid: nil, prev: cid} end)
  end

  @doc """
  Inductive verification of a `#commit` event (indigo `VerifyCommitMessage`,
  DESIGN §3.6): the event's CAR must carry the commit at its root; `rev` and
  `repo` must match it; every create/update op's `cid` must equal the tree's
  value at that path; and inverting the ops on the partial tree must yield
  `prevData`. When `signing_key:` is given the commit signature is checked
  too. Ops without `prev` (legacy) skip the inversion with `:legacy_ops`.

  `event` is the decoded commit body (string keys, CIDs and Bytes wrapped).
  """
  @spec verify_commit_message(map, keyword) ::
          {:ok, %{repo: t, blockstore: Blockstore.t(), ops: [op], inverted: boolean}}
          | {:error, term}
  def verify_commit_message(event, opts \\ [])

  def verify_commit_message(
        %{"repo" => did, "rev" => rev, "blocks" => %Bytes{data: car}, "ops" => raw_ops} = event,
        opts
      ) do
    with :ok <- if(Syntax.valid_did?(did), do: :ok, else: {:error, :invalid_did}),
         :ok <- if(Syntax.valid_tid?(rev), do: :ok, else: {:error, :invalid_rev}),
         {:ok, root, blocks} <- CAR.decode_with_root(car),
         bs = Memory.new(blocks),
         {:ok, repo} <- load(bs, root),
         :ok <- if(repo.commit["rev"] == rev, do: :ok, else: {:error, :rev_mismatch}),
         :ok <- if(repo.commit["did"] == did, do: :ok, else: {:error, :did_mismatch}),
         :ok <- check_sig(repo.commit, opts[:signing_key]),
         {:ok, ops} <- parse_ops(raw_ops),
         :ok <- ops_match_tree(bs, repo, ops),
         {:ok, inverted} <- invert_ops(bs, repo, ops, event["prevData"]) do
      {:ok, %{repo: repo, blockstore: bs, ops: ops, inverted: inverted}}
    end
  end

  def verify_commit_message(_, _), do: {:error, :invalid_commit_event}

  @spec parse_ops(term) :: {:ok, [op]} | {:error, term}
  def parse_ops(raw) when is_list(raw) do
    Enum.reduce_while(raw, {:ok, []}, fn op, {:ok, acc} ->
      case parse_op(op) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        e -> {:halt, e}
      end
    end)
    |> case do
      {:ok, ops} -> {:ok, Enum.reverse(ops)}
      e -> e
    end
  end

  def parse_ops(_), do: {:error, :invalid_ops}

  defp parse_op(%{"action" => "create", "path" => path, "cid" => %CID{} = cid} = op)
       when is_binary(path) do
    if Map.get(op, "prev") == nil,
      do: {:ok, %{action: :create, path: path, cid: cid, prev: nil}},
      else: {:error, {:invalid_op, :create}}
  end

  defp parse_op(%{"action" => "update", "path" => path, "cid" => %CID{} = cid} = op)
       when is_binary(path),
       do: {:ok, %{action: :update, path: path, cid: cid, prev: op["prev"]}}

  defp parse_op(%{"action" => "delete", "path" => path} = op) when is_binary(path) do
    if Map.get(op, "cid") == nil,
      do: {:ok, %{action: :delete, path: path, cid: nil, prev: op["prev"]}},
      else: {:error, {:invalid_op, :delete}}
  end

  defp parse_op(op), do: {:error, {:invalid_op, op}}

  defp ops_match_tree(bs, repo, ops) do
    Enum.find_value(ops, :ok, fn
      %{action: a, path: path, cid: cid} when a in [:create, :update] ->
        with {:ok, _, _} <-
               parse_data_key(path)
               |> then(fn
                 {:ok, c, r} -> {:ok, c, r}
                 :error -> {:error, {:invalid_path, path}}
               end),
             {:ok, ^cid} <- MST.get(bs, repo.data, path) do
          nil
        else
          {:ok, _other} -> {:error, {:op_cid_mismatch, path}}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        nil
    end)
  end

  # Applies the inverse of each op to the partial tree; the result's root
  # must equal prevData. Returns {:ok, true} when checked, {:ok, false} when
  # it could not be (legacy ops without prev, or no prevData).
  defp invert_ops(bs, repo, ops, prev_data) do
    legacy? = Enum.any?(ops, &(&1.action in [:update, :delete] and is_nil(&1.prev)))

    cond do
      legacy? or is_nil(prev_data) ->
        {:ok, false}

      true ->
        result =
          Enum.reduce_while(normalize_ops(ops), {:ok, repo.data}, fn op, {:ok, mst} ->
            inverted =
              case op do
                %{action: :create, path: p} -> MST.delete(bs, mst, p)
                %{action: :update, path: p, prev: prev} -> MST.update(bs, mst, p, prev)
                %{action: :delete, path: p, prev: prev} -> MST.add(bs, mst, p, prev)
              end

            case inverted do
              {:ok, mst} -> {:cont, {:ok, mst}}
              {:error, reason} -> {:halt, {:error, {:inversion_failed, reason}}}
            end
          end)

        with {:ok, mst} <- result,
             {:ok, root, _} <- MST.root(bs, mst) do
          if root == prev_data, do: {:ok, true}, else: {:error, :prev_data_mismatch}
        end
    end
  end

  # indigo NormalizeOps: several ops on one path collapse to the net effect.
  defp normalize_ops(ops) do
    ops
    |> Enum.group_by(& &1.path)
    |> Enum.flat_map(fn {path, group} ->
      first = hd(group)
      last = List.last(group)
      before = first.prev
      after_ = last.cid

      cond do
        length(group) == 1 -> [first]
        before == nil and after_ == nil -> []
        before == nil -> [%{action: :create, path: path, cid: after_, prev: nil}]
        after_ == nil -> [%{action: :delete, path: path, cid: nil, prev: before}]
        before == after_ -> []
        true -> [%{action: :update, path: path, cid: after_, prev: before}]
      end
    end)
  end
end
