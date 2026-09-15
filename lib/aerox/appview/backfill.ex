defmodule Aerox.AppView.Backfill do
  @moduledoc """
  Repo re-synchronisation (DESIGN §15.1; Sync spec, "Record-Level
  Synchronization"): `getRepo` from the owning PDS, verified by the kernel
  (`verify_repo_car`), then compared record by record with what the index holds
  for the DID — a record only in the CAR is indexed, one whose CID differs is
  re-indexed, one only in the index is deleted. Events that arrived meanwhile
  are replayed (`Aerox.AppView.RepoSync.finish_backfill/3`).

  Runs as an Oban job on the core instance (queue `:backfill`); `request/1` is
  idempotent per DID while a job is queued or running. A repo whose queued
  events break the chain again is retried shortly; a failed fetch leaves it
  `desynchronized`, and the next event for it asks again.
  """
  use Oban.Worker,
    queue: :backfill,
    max_attempts: 5,
    unique: [period: 300, states: [:available, :scheduled, :executing]]

  import Ecto.Query
  require Logger
  alias Aerox.ATProto.{Blockstore, CID, Repo}
  alias Aerox.AppView.{Indexing, RepoSync}
  alias Aerox.AppView.Ingest.Indexer
  alias Aerox.AppView.Schema.Record
  alias Aerox.Identity.HTTP

  def request(did) do
    {:ok, _} = Oban.insert(Aerox.Core.Oban, new(%{"did" => did}))
    :ok
  end

  @impl true
  def perform(%Oban.Job{args: %{"did" => did}}) do
    :ok = RepoSync.begin_backfill(did)

    with {:ok, doc} <- Aerox.Identity.resolve_did(Aerox.AppView.Identity, did, force: true),
         pds when is_binary(pds) <- Aerox.ATProto.Identity.pds_endpoint(doc) || {:error, :no_pds},
         {:ok, car} <- fetch_repo(pds, did),
         {:ok, %{records: records, commit: commit, cid: cid, blockstore: bs}} <-
           Repo.verify_repo_car(car, did: did, signing_key: signing_key(doc)) do
      indexed_at = DateTime.utc_now()
      Indexing.ensure_actor(did, indexed_at)
      Indexing.index_handle(did, indexed_at, Aerox.ATProto.Identity.handle(doc))
      reconcile(did, records, bs, indexed_at)

      car_state = %{
        rev: commit["rev"],
        commit_cid: CID.to_string(cid),
        data_cid: CID.to_string(commit["data"])
      }

      case RepoSync.finish_backfill(did, car_state, &Indexer.replay_commit/1) do
        :ok -> :ok
        :resync -> {:snooze, 1}
      end
    else
      {:error, {:http, 404}} ->
        Logger.info("appview: backfill #{did}: repo not found")
        RepoSync.fail_backfill(did)
        :ok

      {:error, reason} ->
        RepoSync.fail_backfill(did)
        {:error, reason}

      other ->
        RepoSync.fail_backfill(did)
        {:error, other}
    end
  end

  # The CAR is the truth; the index is brought to it.
  defp reconcile(did, records, bs, indexed_at) do
    indexed =
      from(r in Record, where: r.did == ^did, select: {r.uri, r.cid})
      |> Aerox.AppView.Repo.all()
      |> Map.new()

    in_car =
      Map.new(records, fn %{path: path, cid: rcid} -> {"at://#{did}/#{path}", rcid} end)

    for {uri, rcid} <- in_car, indexed[uri] != CID.to_string(rcid) do
      with {:ok, record} <- Blockstore.get_value(bs, rcid) do
        _ = Indexing.index_record(uri, CID.to_string(rcid), record, indexed_at, action: :update)
      end
    end

    for {uri, _} <- indexed, not Map.has_key?(in_car, uri) do
      Indexing.delete_record(uri)
    end

    :ok
  end

  @doc """
  The account's hosting status as its current PDS reports it
  (`com.atproto.sync.getRepoStatus`, after a fresh DID resolution): `"active"`,
  the reported status, or `"deleted"` for an unknown repo.
  """
  @spec fetch_repo_status(String.t()) :: {:ok, String.t()} | {:error, term}
  def fetch_repo_status(did) do
    with {:ok, doc} <- Aerox.Identity.resolve_did(Aerox.AppView.Identity, did, force: true),
         pds when is_binary(pds) <- Aerox.ATProto.Identity.pds_endpoint(doc) || {:error, :no_pds} do
      url = "#{pds}/xrpc/com.atproto.sync.getRepoStatus?did=#{URI.encode_www_form(did)}"

      case HTTP.get(url, http_opts(timeout: 10_000, max_bytes: 1_000_000)) do
        {:ok, 200, _, body} ->
          case Jason.decode(body) do
            {:ok, %{"active" => true}} -> {:ok, "active"}
            {:ok, %{"status" => status}} when is_binary(status) -> {:ok, status}
            {:ok, %{"active" => false}} -> {:ok, "inactive"}
            _ -> {:error, :invalid_response}
          end

        {:ok, 404, _, _} ->
          {:ok, "deleted"}

        {:ok, status, _, _} ->
          {:error, {:http, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp http_opts(opts),
    do: opts ++ Keyword.take(Application.get_env(:aerox, __MODULE__, []), [:plug, :allow_private])

  defp fetch_repo(pds, did) do
    opts = http_opts(timeout: 60_000, max_bytes: 200 * 1024 * 1024)

    case HTTP.get("#{pds}/xrpc/com.atproto.sync.getRepo?did=#{URI.encode_www_form(did)}", opts) do
      {:ok, 200, _, car} -> {:ok, car}
      {:ok, status, _, _} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp signing_key(doc) do
    case Aerox.ATProto.Identity.signing_did_key(doc) do
      {:ok, key} -> key
      _ -> nil
    end
  end
end
