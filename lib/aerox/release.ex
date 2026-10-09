defmodule Aerox.Release do
  @moduledoc """
  Release tasks run with `bin/aerox eval "Aerox.Release.migrate()"` (no Mix
  in production). Migrates every repo in DESIGN §4.6 order; each repo owns its
  own schema, so the order only matters for the first boot.
  """
  use Boundary,
    top_level?: true,
    deps: [Aerox.PDS, Aerox.PLC, Aerox.Relay, Aerox.AppView, Aerox.Labeler]

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
        case source |> Aerox.PLC.Import.read!() |> Aerox.PLC.Import.run() do
          {:ok, %{dids: dids, added: added}} ->
            IO.puts("PLC import: #{dids} DIDs, #{added} operations added")

          {:error, failed} ->
            for {did, reason} <- failed, do: IO.puts(:stderr, "FAIL #{did}: #{inspect(reason)}")
            raise "PLC import: #{length(failed)} DIDs failed validation; nothing was written"
        end
      end)

    :ok
  end

  def rollback(repo, version) do
    Application.load(@app)
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end
end
