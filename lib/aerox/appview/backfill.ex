defmodule Aerox.AppView.Backfill do
  @moduledoc """
  Repo backfill (DESIGN §15.1): `getRepo` from the owning PDS, verified by
  the kernel (`verify_repo_car`), every record indexed as if live. Runs as
  an Oban job on the core instance (queue `:backfill`); `request/1` is
  idempotent per DID while a job is queued. Live indexing and backfill of
  one repo never run at once: the job takes the DID's Registry key.
  """
  use Oban.Worker,
    queue: :backfill,
    max_attempts: 5,
    unique: [period: 300, states: [:available, :scheduled, :executing]]

  require Logger
  alias Aerox.ATProto.{CID, Repo}
  alias Aerox.AppView.Indexing
  alias Aerox.Identity.HTTP

  def request(did) do
    {:ok, _} = Oban.insert(Aerox.Core.Oban, new(%{"did" => did}))
    :ok
  end

  @impl true
  def perform(%Oban.Job{args: %{"did" => did}}) do
    with {:ok, doc} <- Aerox.Identity.resolve_did(Aerox.AppView.Identity, did, force: true),
         pds when is_binary(pds) <- Aerox.ATProto.Identity.pds_endpoint(doc) || {:error, :no_pds},
         {:ok, car} <- fetch_repo(pds, did),
         {:ok, %{records: ops, commit: commit, cid: cid, blockstore: bs}} <-
           Repo.verify_repo_car(car, did: did, signing_key: signing_key(doc)) do
      indexed_at = DateTime.utc_now()
      Indexing.ensure_actor(did, indexed_at)
      Indexing.index_handle(did, indexed_at, Aerox.ATProto.Identity.handle(doc))

      Enum.each(ops, fn %{path: path, cid: rcid} ->
        with {:ok, record} <- Aerox.ATProto.Blockstore.get_value(bs, rcid) do
          _ =
            Indexing.index_record("at://#{did}/#{path}", CID.to_string(rcid), record, indexed_at,
              action: :update
            )
        end
      end)

      Indexing.set_commit_last_seen(did, CID.to_string(cid), commit["rev"])
      :ok
    else
      {:error, {:http, 404}} ->
        Logger.info("appview: backfill #{did}: repo not found")
        :ok

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  defp fetch_repo(pds, did) do
    opts =
      [timeout: 60_000, max_bytes: 200 * 1024 * 1024] ++
        Keyword.take(Application.get_env(:aerox, __MODULE__, []), [:plug, :allow_private])

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
