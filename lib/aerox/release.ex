defmodule Aerox.Release do
  @moduledoc """
  Release tasks run with `bin/aerox eval "Aerox.Release.migrate()"` (no Mix
  in production). Migrates every repo in DESIGN §4.6 order; each repo owns its
  own schema, so the order only matters for the first boot.
  """
  use Boundary,
    top_level?: true,
    deps: [Aerox.PDS, Aerox.PLC, Aerox.Relay, Aerox.AppView, Aerox.Labeler, Aerox.Labeler.Setup]

  alias Aerox.PLC.Import

  @app :aerox
  @repos [
    Aerox.PDS.Repo,
    Aerox.PLC.Repo,
    Aerox.Relay.Repo,
    Aerox.AppView.Repo,
    Aerox.Labeler.Repo
  ]

  def migrate do
    Application.ensure_all_started(:ssl)
    Application.load(@app)

    for repo <- @repos do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc "`Aerox.PLC.Import` from a directory URL or an export file; raises when any DID fails."
  def import_plc(source) do
    Application.ensure_all_started(:req)
    Application.load(@app)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Aerox.PLC.Repo, fn _ ->
        source |> Import.read!() |> Import.run() |> report_plc_import()
      end)

    :ok
  end

  defp report_plc_import({:ok, %{dids: dids, added: added}}),
    do: IO.puts("PLC import: #{dids} DIDs, #{added} operations added")

  defp report_plc_import({:error, failed}) do
    for {did, reason} <- failed, do: IO.puts(:stderr, "FAIL #{did}: #{inspect(reason)}")
    raise "PLC import: #{length(failed)} DIDs failed validation; nothing was written"
  end

  @doc """
  Queues an AppView backfill for every repo `url` lists
  (`com.atproto.sync.listRepos`: a PDS or a relay). The AppView indexes a
  repo it has never seen only when a new commit arrives (DESIGN §13.4 point
  2), so after an import or a first start this is what fills it. The running
  node's `backfill` queue does the work; this only inserts the jobs.
  """
  def backfill_appview(url) do
    Enum.each([:req, :oban], &Application.ensure_all_started/1)
    Application.load(@app)

    {:ok, _, _} =
      Ecto.Migrator.with_repo(Aerox.AppView.Repo, fn _ ->
        oban =
          Keyword.merge(Application.fetch_env!(:aerox, Oban.Core), queues: false, plugins: false)

        {:ok, _} = Oban.start_link(oban)
        dids = list_repos(String.trim_trailing(url, "/"), nil, [])
        jobs = Enum.map(dids, &Aerox.AppView.Backfill.new(%{"did" => &1}))
        Oban.insert_all(Aerox.Core.Oban, jobs)
        IO.puts("AppView backfill: #{length(jobs)} repos queued from #{url}")
      end)

    :ok
  end

  @doc """
  `mix aerox.labeler.setup` for a release: creates (or completes) the
  labeler's account on this PDS and prints its DID — export it as
  `LABELER_DID`. Signup and the DID-document update need the whole stack, so
  this boots the application; run it with `PORT` set to a free port beside a
  live node.
  """
  def setup_labeler(handle, password) do
    {:ok, _} = Application.ensure_all_started(@app)
    result = Aerox.Labeler.Setup.ensure_account!(handle: handle, password: password)
    IO.puts("labeler #{if result.created?, do: "created", else: "ready"}: #{result.did}")
  end

  defp list_repos(url, cursor, acc) do
    params = [limit: 1000] ++ if(cursor, do: [cursor: cursor], else: [])
    body = Req.get!(url <> "/xrpc/com.atproto.sync.listRepos", params: params).body
    acc = acc ++ Enum.map(body["repos"], & &1["did"])
    if body["cursor"] && body["repos"] != [], do: list_repos(url, body["cursor"], acc), else: acc
  end

  def rollback(repo, version) do
    Application.load(@app)
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end
end
