defmodule Mix.Tasks.Aerox.Plc.Import do
  @shortdoc "Copy another PLC directory's operation log into ours (never submits an op)"
  @moduledoc """
  `Aerox.PLC.Import`: reads `--from` — a directory's base URL, paged through
  `/export`, or a file of export lines — validates every DID's log and
  writes them all, or nothing. Re-runnable.

      mix aerox.plc.import --from https://plc.example
      mix aerox.plc.import --from export.jsonl

  In a release: `bin/aerox eval 'Aerox.Release.import_plc("https://plc.example")'`.
  """
  use Boundary, top_level?: true, deps: [Aerox.Release]
  use Mix.Task

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [from: :string])
    Mix.Task.run("app.config")
    Aerox.Release.import_plc(opts[:from] || Mix.raise("--from is required"))
  end
end
