defmodule Aerox.Release do
  @moduledoc """
  Release tasks run with `bin/aerox eval "Aerox.Release.migrate()"` (no Mix
  in production). Migrates every repo in DESIGN §4.6 order; each repo owns its
  own schema, so the order only matters for the first boot.
  """
  use Boundary,
    top_level?: true,
    deps: [Aerox.PDS, Aerox.PLC, Aerox.Relay, Aerox.AppView, Aerox.Labeler]

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

  def rollback(repo, version) do
    Application.load(@app)
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end
end
