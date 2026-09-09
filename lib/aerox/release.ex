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

  def rollback(repo, version) do
    Application.load(@app)
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end
end
