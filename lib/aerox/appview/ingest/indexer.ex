defmodule Aerox.AppView.Ingest.Indexer do
  @moduledoc """
  Turns a firehose event into index writes (DESIGN §15.1): `#commit` → kernel
  verification (`Aerox.ATProto.Repo.verify_commit_message`, signature
  included) → `Aerox.AppView.RepoSync`, which decides whether the commit
  follows on from the repo's stored state, and if so one
  `index_record`/`delete_record` per op; `#sync` → verified and handed to
  `RepoSync` (a reset means a backfill); `#identity` → re-resolve the handle;
  `#account` → status. Invalid events are logged and skipped, never indexed.
  """
  require Logger
  alias Aerox.ATProto.{Blockstore, Bytes, CAR, CID, Repo, Syntax}
  alias Aerox.ATProto.Blockstore.Memory
  alias Aerox.AppView.{Indexing, RepoSync}

  @type result :: :ok | {:skip, term}

  @spec process(String.t(), map) :: result
  def process("#commit", %{"repo" => did, "rev" => rev, "blocks" => %Bytes{}} = body) do
    case verify_commit(did, body) do
      {:ok, verified} ->
        RepoSync.on_commit(did, body, state_of(verified.repo), fn ->
          apply_commit(did, body, verified)
        end)

      {:error, reason} ->
        Logger.warning("appview: invalid commit did=#{did} rev=#{rev} reason=#{inspect(reason)}")
        {:skip, reason}
    end
  end

  def process("#commit", _), do: {:skip, :invalid_commit_event}

  def process("#sync", %{"did" => did, "rev" => rev, "blocks" => %Bytes{data: car}} = body) do
    with {:ok, root, blocks} <- CAR.decode_with_root(car),
         {:ok, repo} <- Repo.load(Memory.new(blocks), root),
         :ok <- if(repo.commit["did"] == did, do: :ok, else: {:error, :did_mismatch}),
         :ok <- if(repo.commit["rev"] == rev, do: :ok, else: {:error, :rev_mismatch}),
         :ok <- verify_signature(did, repo.commit) do
      RepoSync.on_sync(did, body, state_of(repo))
    else
      {:error, reason} ->
        Logger.warning("appview: invalid sync did=#{did} rev=#{rev} reason=#{inspect(reason)}")
        {:skip, reason}

      other ->
        {:skip, other}
    end
  end

  def process("#sync", _), do: {:skip, :invalid_sync_event}

  def process("#identity", %{"did" => did} = body) do
    Aerox.Identity.invalidate(Aerox.AppView.Identity, did)
    Indexing.index_handle(did, time(body["time"]), body["handle"])
    :ok
  end

  def process("#account", %{"did" => did, "active" => active} = body) do
    status = if active, do: "active", else: body["status"] || "inactive"
    Indexing.update_actor_status(did, upstream_status: status)
    if status == "deleted", do: Indexing.unindex_actor(did)
    :ok
  end

  def process(type, _body), do: {:skip, {:unhandled, type}}

  @doc """
  Verifies and applies a `#commit` that was queued while its repo was being
  backfilled; returns the state it leaves the repo in
  (`RepoSync.finish_backfill/3`).
  """
  @spec replay_commit(map) :: {:ok, RepoSync.state()} | {:error, term}
  def replay_commit(%{"repo" => did} = body) do
    with {:ok, verified} <- verify_commit(did, body) do
      apply_commit(did, body, verified)
      {:ok, state_of(verified.repo)}
    end
  end

  @doc "The sync state a loaded repo commit stands for."
  def state_of(repo) do
    %{
      rev: repo.commit["rev"],
      commit_cid: CID.to_string(repo.cid),
      data_cid: CID.to_string(repo.commit["data"])
    }
  end

  defp apply_commit(did, body, %{blockstore: bs, ops: ops}) do
    indexed_at = time(body["time"])
    Indexing.ensure_actor(did, indexed_at)
    Enum.each(ops, &apply_op(did, &1, bs, indexed_at))
  end

  # Sync spec, validation checklist: an account without a working identity
  # (no signing key) is ignored; a signature that fails against the cached key
  # is retried once against a freshly resolved one, in case the key rotated.
  defp verify_commit(did, body) do
    with {:ok, key} <- signing_key(did, []) do
      case Repo.verify_commit_message(body, signing_key: key) do
        {:error, :invalid_signature} ->
          with {:ok, fresh} <- signing_key(did, force: true),
               do: Repo.verify_commit_message(body, signing_key: fresh)

        other ->
          other
      end
    end
  end

  defp verify_signature(did, commit) do
    with {:ok, key} <- signing_key(did, []) do
      if Repo.verify_commit_sig(commit, key) do
        :ok
      else
        with {:ok, fresh} <- signing_key(did, force: true) do
          if Repo.verify_commit_sig(commit, fresh), do: :ok, else: {:error, :invalid_signature}
        end
      end
    end
  end

  defp apply_op(did, %{action: action, path: path, cid: cid}, bs, indexed_at)
       when action in [:create, :update] do
    uri = "at://#{did}/#{path}"

    case Blockstore.get_value(bs, cid) do
      {:ok, record} ->
        case Indexing.index_record(uri, CID.to_string(cid), record, indexed_at, action: action) do
          :ok -> :ok
          {:error, reason} -> Logger.debug("appview: not indexed #{uri}: #{inspect(reason)}")
        end

      _ ->
        Logger.warning("appview: record block missing #{uri}")
    end
  end

  defp apply_op(did, %{action: :delete, path: path}, _bs, _indexed_at) do
    Indexing.delete_record("at://#{did}/#{path}")
  end

  defp signing_key(did, opts) do
    case Aerox.Identity.resolve_signing_key(Aerox.AppView.Identity, did, opts) do
      {:ok, key} -> {:ok, key}
      {:error, reason} -> {:error, {:no_identity, reason}}
    end
  end

  defp time(value) do
    case value && Syntax.parse_datetime(value) do
      {:ok, dt} -> Aerox.AppView.Plugin.Helpers.usec(dt)
      _ -> DateTime.utc_now()
    end
  end
end
