defmodule Aerox.Jetstream.Bootstrap do
  @moduledoc """
  The first start (docs/README.md §4.1–4.2). While the live consumer captures
  relay events into `bootstrap_live`, every repo the Relay lists is downloaded
  and appended as `create` rows at its CAR's rev. Then the captured events are
  merged into the log in order, dropping commit and `#sync` rows at or below
  the backfilled rev of their repo (identity and account rows always pass),
  the active segment is sealed, compaction runs, and the phase becomes
  `steady_state` — the cut-over happens inside the consumer, so no event
  lands between the last merged row and the switch.
  """
  use GenServer, restart: :transient
  import Ecto.Query
  require Logger
  alias Aerox.Jetstream.{Config, Event, Ingest, Repo, Repos, Store, Writer}
  alias Aerox.Jetstream.Schema.{BootstrapLive, RepoRow}

  @concurrency 4
  @merge_batch 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Stores rows captured during bootstrap, with the relay cursor they came from."
  def capture(rows, cursor) do
    Repo.transaction(fn ->
      Repo.insert_all(
        BootstrapLive,
        Enum.map(
          rows,
          &(Map.take(Map.from_struct(&1), [:did, :collection, :rkey, :rev, :payload])
            |> Map.put(:kind, Event.kind_code(&1.kind)))
        )
      )

      Store.put("relay_cursor", cursor)
    end)

    :ok
  end

  @impl true
  def init(_) do
    if Store.steady_state?(), do: :ignore, else: {:ok, %{}, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    Logger.info("jetstream: bootstrap starting")
    :ok = crawl()
    :ok = backfill()
    :ok = merge()
    Logger.info("jetstream: bootstrap complete; steady state")
    {:stop, :normal, state}
  end

  @doc "Lists the Relay's repos into the `repo` table (`not_started`)."
  def crawl(cursor \\ nil) do
    url =
      relay_http() <>
        "/xrpc/com.atproto.sync.listRepos?limit=1000" <>
        if(cursor, do: "&cursor=" <> URI.encode_www_form(cursor), else: "")

    opts =
      Keyword.take(Application.get_env(:aerox, Aerox.Jetstream.Repos, []), [:plug, :allow_private])

    case Aerox.Identity.HTTP.get(url, [timeout: 30_000, max_bytes: 50_000_000] ++ opts) do
      {:ok, 200, _, body} ->
        %{"repos" => repos} = decoded = Jason.decode!(body)
        for %{"did" => did} = r <- repos, r["active"] != false, do: Repos.ensure(did)
        if next = decoded["cursor"], do: crawl(next), else: :ok

      other ->
        Logger.error("jetstream: bootstrap listRepos failed: #{inspect(other)}")
        Process.sleep(5_000)
        crawl(cursor)
    end
  end

  @doc "Downloads every repo not yet synchronised, a few at a time; each gets two tries."
  def backfill do
    dids =
      from(r in RepoRow,
        where: r.status in ["not_started", "failed"] and r.attempts < 2,
        select: r.did
      )
      |> Repo.all()

    dids
    |> Task.async_stream(&Repos.backfill/1,
      max_concurrency: @concurrency,
      timeout: :infinity,
      ordered: false
    )
    |> Stream.run()

    if dids == [] or
         from(r in RepoRow, where: r.status in ["not_started", "failed"] and r.attempts < 2)
         |> Repo.exists?() == false,
       do: :ok,
       else: backfill()
  end

  @doc "Merges the captured live rows and switches to the steady state."
  def merge do
    case Ingest.exclusive(&merge_step/0) do
      :more ->
        merge()

      :done ->
        :ok = Writer.rotate()
        _ = Aerox.Jetstream.Compactor.run_now()
        :ok
    end
  end

  @doc """
  One merge batch; `:done` (and the phase flipped) once nothing is left. Run
  inside the consumer, one batch per section, so it keeps up in between.
  """
  def merge_step do
    batch = from(b in BootstrapLive, order_by: [asc: b.id], limit: @merge_batch) |> Repo.all()

    case batch do
      [] ->
        Store.put("phase", "steady_state")
        :done

      rows ->
        revs = rows |> Enum.map(& &1.did) |> Enum.uniq() |> Repos.backfill_revs()

        kept =
          for r <- rows,
              {:ok, kind} = Event.kind_from_code(r.kind),
              keep?(kind, r, revs[r.did]) do
            %Event{
              kind: kind,
              did: r.did,
              collection: r.collection,
              rkey: r.rkey,
              rev: r.rev,
              payload: r.payload
            }
          end

        if kept != [], do: {:ok, _} = Writer.append(kept)
        last = List.last(rows).id
        Repo.delete_all(from(b in BootstrapLive, where: b.id <= ^last))
        :more
    end
  end

  defp keep?(kind, _row, _rev) when kind in [:identity, :account], do: true
  defp keep?(_kind, _row, nil), do: true
  defp keep?(_kind, row, backfill_rev), do: row.rev > backfill_rev

  defp relay_http do
    uri = URI.parse(Config.relay_url())
    scheme = if uri.scheme in ["wss", "https"], do: "https", else: "http"
    URI.to_string(%URI{uri | scheme: scheme, path: nil, query: nil})
  end
end
