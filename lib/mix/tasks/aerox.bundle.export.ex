defmodule Mix.Tasks.Aerox.Bundle.Export do
  @shortdoc "Export an account (or every account) from aerox_pds as an encrypted bundle"
  @moduledoc """
  DESIGN §13.0 / §13.2. Writes `<out>/<did>/` per account.

      mix aerox.bundle.export --did did:plc:… --out <dir> [--recipient <jwk-or-pem>]…
                              [--passphrase-env VAR] [--takeover] [--insecure-plaintext]
      mix aerox.bundle.export --all --out <dir> …

    * `--did` (repeatable) or `--all`: which accounts.
    * `--recipient`: a P-256 or X25519 **public** key, as a PEM/JWK file path
      or literal; repeatable, every recipient can decrypt.
    * `--passphrase-env VAR`: also wrap the content key under the passphrase
      in environment variable `VAR` (never on the command line).
    * `--takeover`: include `seq.car` (the account's firehose history).
    * `--insecure-plaintext`: write without encryption (air-gapped hosts only);
      refused otherwise when no recipient or passphrase is given.

  Runs against the PDS database only; the PDS may be running for an export.
  Secrets are never printed.
  """
  use Boundary, top_level?: true, deps: [Aerox.Interop, Aerox.PDS]
  use Mix.Task
  import Ecto.Query
  alias Aerox.Interop.Bundle.{Crypto, Postgres}
  alias Aerox.Interop.Runtime

  @switches [
    did: :keep,
    all: :boolean,
    out: :string,
    recipient: :keep,
    passphrase_env: :string,
    takeover: :boolean,
    insecure_plaintext: :boolean
  ]

  @impl true
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")
    out = opts[:out] || Mix.raise("--out <dir> is required")
    recipients = recipients!(opts)

    if recipients == [] and not Keyword.get(opts, :insecure_plaintext, false),
      do:
        Mix.raise(
          "refusing to write a plaintext bundle: give --recipient / --passphrase-env, or --insecure-plaintext"
        )

    Runtime.start()

    dids =
      cond do
        opts[:all] ->
          Aerox.PDS.Repo.all(from(a in Aerox.PDS.Schema.Actor, select: a.did, order_by: a.did))

        Keyword.get_values(opts, :did) != [] ->
          Keyword.get_values(opts, :did)

        true ->
          Mix.raise("give --did <did> (repeatable) or --all")
      end

    export_opts = [
      recipients: recipients,
      insecure_plaintext: Keyword.get(opts, :insecure_plaintext, false),
      takeover: Keyword.get(opts, :takeover, false)
    ]

    results =
      for did <- dids do
        dir = Path.join(out, did)

        case Postgres.export(did, dir, export_opts) do
          {:ok, manifest} ->
            c = manifest["counts"]

            Runtime.info(
              "exported #{did} → #{dir} (#{c["records"]} records, #{c["blocks"]} blocks, #{c["blobs"]} blobs, #{c["seq_events"]} seq events)"
            )

            :ok

          {:error, reason} ->
            Runtime.error("FAILED #{did}: #{inspect(reason)}")
            :error
        end
      end

    failed = Enum.count(results, &(&1 == :error))
    Runtime.info("#{length(dids) - failed} exported, #{failed} failed")
    if failed > 0 or dids == [], do: Mix.raise("export incomplete")
  end

  defp recipients!(opts) do
    keys =
      for spec <- Keyword.get_values(opts, :recipient) do
        case Crypto.parse_jwk(spec) do
          {:ok, jwk} -> {:jwk, jwk}
          {:error, reason} -> Mix.raise("--recipient #{spec}: #{inspect(reason)}")
        end
      end

    pass =
      case opts[:passphrase_env] do
        nil ->
          []

        var ->
          [
            {:passphrase,
             System.get_env(var) || Mix.raise("environment variable #{var} is not set")}
          ]
      end

    keys ++ pass
  end
end
