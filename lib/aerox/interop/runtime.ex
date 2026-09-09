defmodule Aerox.Interop.Runtime do
  @moduledoc """
  What a bundle mix task starts: the PDS repo and the libraries the adapters
  use — deliberately **not** the application (no endpoint, no sequencer, no
  Oban). DESIGN §13.2: the import runs on the target machine while the PDS
  is stopped; with `--takeover` that is a requirement, since the running
  sequencer only reads `max(seq)` at start.
  """

  @apps [
    :logger,
    :crypto,
    :ssl,
    :jason,
    :jose,
    :ecto_sql,
    :postgrex,
    :ex_secp256k1,
    :scrypt,
    :telemetry
  ]

  @doc """
  Loads config and starts the PDS repo (idempotent). The logger is held at
  `:info` or above: Ecto's debug logging would print query parameters, and
  those include password hashes and signing keys during an import.
  """
  @spec start() :: :ok
  def start do
    Mix.Task.run("app.config", [])
    if Logger.compare_levels(Logger.level(), :info) == :lt, do: Logger.configure(level: :info)
    Enum.each(@apps, &Application.ensure_all_started/1)

    case Aerox.PDS.Repo.start_link(pool_size: 4) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end

  @doc "Prints a line without ever echoing a secret: the caller passes text it composed itself."
  def info(text), do: Mix.shell().info(text)
  def error(text), do: Mix.shell().error(text)
end
