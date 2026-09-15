defmodule Aerox.Jetstream.Repos do
  @moduledoc """
  Whole-repo downloads for Jetstream: the bootstrap backfill, `#sync` resyncs,
  and retries of repos that failed (docs/README.md §4.1–4.3, 4.5).

  A download resolves the DID to its PDS and signing key, fetches
  `com.atproto.sync.getRepo`, and verifies the CAR (signature and MST) before
  a row is written. A resync appends the replacement rows as
  `create_resync` after the `#sync` row that tombstones the DID's older rows;
  a retry that is not answering a live `#sync` writes a synthetic one first.
  """
  import Ecto.Query
  require Logger
  alias Aerox.ATProto.{CAR, Identity}
  alias Aerox.Jetstream.{Convert, Event, Repo, Writer}
  alias Aerox.Jetstream.Schema.RepoRow

  @chunk 1000

  @doc "Downloads and verifies a repo: `{:ok, %{rev, cid, commit_bytes, records, blockstore, pds}}`."
  def fetch(did) do
    with {:ok, doc} <- Aerox.Identity.Resolver.resolve_did(did, plc_url: plc_url()),
         pds when is_binary(pds) <- Identity.pds_endpoint(doc) || {:error, :no_pds},
         {:ok, key} <- Identity.signing_did_key(doc) |> ok_or(:no_signing_key),
         {:ok, car} <- get_repo(pds, did),
         {:ok, %{records: records, commit: commit, cid: cid, blockstore: bs}} <-
           Aerox.ATProto.Repo.verify_repo_car(car, did: did, signing_key: key),
         {:ok, commit_bytes} <- Aerox.ATProto.Blockstore.get(bs, cid) |> ok_or(:missing_commit) do
      {:ok,
       %{
         rev: commit["rev"],
         cid: cid,
         commit_bytes: commit_bytes,
         records: records,
         blockstore: bs,
         pds: pds
       }}
    end
  end

  defp get_repo(pds, did) do
    opts =
      [timeout: 120_000, max_bytes: 1024 * 1024 * 1024] ++
        Keyword.take(Application.get_env(:aerox, __MODULE__, []), [:plug, :allow_private])

    case Aerox.Identity.HTTP.get(
           pds <> "/xrpc/com.atproto.sync.getRepo?did=" <> URI.encode_www_form(did),
           opts
         ) do
      {:ok, 200, _, car} -> {:ok, car}
      {:ok, status, _, _} -> {:error, {:http, status}}
      {:error, _} = e -> e
    end
  end

  @doc "The bootstrap snapshot of a repo: `create` rows at the CAR's rev, recorded as the backfill rev."
  def backfill(did) do
    with {:ok, repo} <- fetch(did) do
      rows = Convert.repo_rows(did, repo.rev, repo.records, repo.blockstore, :create)
      :ok = append_chunked(rows)
      mark(did, "synchronized", repo.pds, repo.rev)
      {:ok, repo.rev}
    else
      {:error, reason} = e ->
        fail(did, reason)
        e
    end
  end

  @doc """
  Re-synchronises a repo. `live_sync_rev` is the rev of the `#sync` row just
  appended; without one a synthetic `#sync` row is written first. A PDS whose
  repo is older than that `#sync` is asked again later.
  """
  def resync(did, live_sync_rev \\ nil) do
    with {:ok, repo} <- fetch(did),
         :ok <-
           if(live_sync_rev && repo.rev < live_sync_rev, do: {:error, :stale_repo}, else: :ok) do
      unless live_sync_rev, do: {:ok, _} = Writer.append([synthetic_sync(did, repo)])
      :ok = append_chunked(Convert.repo_rows(did, repo.rev, repo.records, repo.blockstore))
      mark(did, "synchronized", repo.pds, repo.rev)
      :ok
    else
      {:error, reason} = e ->
        fail(did, reason)
        e
    end
  end

  defp synthetic_sync(did, repo) do
    blocks = CAR.encode(repo.cid, [{repo.cid, repo.commit_bytes}])

    %Event{
      kind: :sync,
      did: did,
      rev: repo.rev,
      payload:
        Aerox.ATProto.DagCBOR.encode(%{
          "did" => did,
          "rev" => repo.rev,
          "blocks" => Aerox.ATProto.Bytes.new(blocks),
          "seq" => 0,
          "time" => Aerox.ATProto.Syntax.format_datetime(DateTime.utc_now())
        })
    }
  end

  defp append_chunked(rows) do
    rows
    |> Enum.chunk_every(@chunk)
    |> Enum.each(fn chunk -> {:ok, _} = Writer.append(chunk) end)
  end

  # --------------------------------------------------------- bookkeeping

  def mark(did, status, pds \\ nil, rev \\ nil) do
    Repo.insert_all(
      RepoRow,
      [
        %{
          did: did,
          status: status,
          pds: pds,
          backfill_rev: rev,
          attempts: 0,
          next_attempt_at: nil,
          error: nil,
          updated_at: DateTime.utc_now()
        }
      ],
      on_conflict:
        {:replace,
         [:status, :pds, :backfill_rev, :attempts, :next_attempt_at, :error, :updated_at]},
      conflict_target: :did
    )

    :ok
  end

  def ensure(did) do
    Repo.insert_all(
      RepoRow,
      [%{did: did, status: "not_started", attempts: 0, updated_at: DateTime.utc_now()}],
      on_conflict: :nothing
    )
  end

  defp fail(did, reason) do
    now = DateTime.utc_now()
    attempts = (Repo.one(from(r in RepoRow, where: r.did == ^did, select: r.attempts)) || 0) + 1
    delay_s = min(:math.pow(2, attempts) * 60, 86_400) |> trunc()
    Logger.info("jetstream: repo #{did} failed (attempt #{attempts}): #{inspect(reason)}")

    Repo.insert_all(
      RepoRow,
      [
        %{
          did: did,
          status: "failed",
          attempts: attempts,
          next_attempt_at: DateTime.add(now, delay_s),
          error: inspect(reason),
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:status, :attempts, :next_attempt_at, :error, :updated_at]},
      conflict_target: :did
    )
  end

  @doc "Repos due for a retry."
  def due(limit) do
    now = DateTime.utc_now()

    from(r in RepoRow,
      where: r.status == "failed" and r.next_attempt_at <= ^now,
      select: r.did,
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "The backfill rev of each DID given (for the merge filter)."
  def backfill_revs(dids) do
    from(r in RepoRow,
      where: r.did in ^dids and not is_nil(r.backfill_rev),
      select: {r.did, r.backfill_rev}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp plc_url, do: Application.get_env(:aerox, :plc_url) || "https://plc.directory"
  defp ok_or({:ok, v}, _), do: {:ok, v}
  defp ok_or(:error, reason), do: {:error, reason}
  defp ok_or(_, reason), do: {:error, reason}
end
