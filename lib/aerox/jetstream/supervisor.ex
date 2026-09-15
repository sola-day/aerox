defmodule Aerox.Jetstream.Supervisor do
  @moduledoc "The Jetstream subtree: repo, manifest, then — unless `workers: false` — the writer, the relay ingest and the maintenance loops."
  alias Aerox.Jetstream.Config

  def children do
    base = [Aerox.Jetstream.Repo, Aerox.Jetstream.Manifest]

    if Config.workers?() do
      base ++
        [
          {Task.Supervisor, name: Aerox.Jetstream.TaskSupervisor},
          Aerox.Jetstream.Writer,
          Aerox.Jetstream.Compactor,
          Aerox.Jetstream.Resyncer,
          Aerox.Jetstream.Ingest,
          Aerox.Jetstream.Bootstrap
        ]
    else
      base ++ [{Task.Supervisor, name: Aerox.Jetstream.TaskSupervisor}]
    end
  end
end
