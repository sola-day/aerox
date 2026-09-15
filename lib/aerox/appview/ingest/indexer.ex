defmodule Aerox.AppView.Ingest.Indexer do
  @moduledoc """
  Turns a verified firehose event into index writes (DESIGN §15.1):
  `#commit` → kernel verification (`Aerox.ATProto.Repo.verify_commit_message`)
  → one `index_record`/`delete_record` per op → `actor_sync`; `#identity` →
  re-resolve the handle; `#account` → status; `#sync` → mark for backfill.
  Invalid commits are logged and skipped, never indexed.
  """
  require Logger
  alias Aerox.ATProto.{Blockstore, Bytes, CID, Repo, Syntax}
  alias Aerox.AppView.{Indexing, Backfill}
  alias Aerox.AppView.Schema.ActorSync

  @type result :: :ok | {:skip, term}

  @spec process(String.t(), map) :: result
  def process("#commit", %{"repo" => did, "rev" => rev, "blocks" => %Bytes{}} = body) do
    indexed_at = time(body["time"])

    case Repo.verify_commit_message(body, signing_key: signing_key(did)) do
      {:ok, %{repo: repo, blockstore: bs, ops: ops}} ->
        Indexing.ensure_actor(did, indexed_at)
        first_sight = is_nil(Aerox.AppView.Repo.get(ActorSync, did))

        # `tooBig` is deprecated and ignored (Sync spec): the commit verified,
        # so its blocks are complete whatever the flag says
        Enum.each(ops, &apply_op(did, &1, bs, indexed_at))

        Indexing.set_commit_last_seen(did, CID.to_string(repo.cid), rev)
        # DESIGN §15.1: a repo seen for the first time is backfilled
        if first_sight, do: Backfill.request(did)
        :ok

      {:error, reason} ->
        Logger.warning("appview: invalid commit did=#{did} rev=#{rev} reason=#{inspect(reason)}")
        {:skip, reason}
    end
  end

  def process("#commit", _), do: {:skip, :invalid_commit_event}

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

  def process("#sync", %{"did" => did}) do
    Backfill.request(did)
    :ok
  end

  def process(type, _body), do: {:skip, {:unhandled, type}}

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

  defp signing_key(did) do
    case Aerox.Identity.resolve_signing_key(Aerox.AppView.Identity, did, []) do
      {:ok, key} -> key
      _ -> nil
    end
  end

  defp time(value) do
    case value && Syntax.parse_datetime(value) do
      {:ok, dt} -> Aerox.AppView.Plugin.Helpers.usec(dt)
      _ -> DateTime.utc_now()
    end
  end
end
