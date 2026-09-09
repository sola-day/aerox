defmodule Mix.Tasks.Aerox.Interop.FromPds do
  @shortdoc "Reference-PDS <data> directory → bundles (MIX_ENV=tool)"
  @moduledoc """
  DESIGN §13.2: reads a stock reference-PDS data directory (a consistent
  snapshot — `.backup` copies or a stopped PDS) and writes one bundle per
  account under `--out`, ready for `mix aerox.bundle.import`.

      MIX_ENV=tool mix aerox.interop.from_pds --data <dir> --out <dir> [--did …]…
          [--blobs <dir>] [--host <source pds hostname>] [--pds-version 0.4]
          [--takeover] [--recipient <jwk-or-pem>]… [--passphrase-env VAR] [--insecure-plaintext]

  Accounts whose `#atproto_pds` would change on import into *this* instance
  (`--host` differs from the configured PDS hostname) are listed as PLC
  operations; none is submitted (§13.5). Secrets never reach the log.
  Needs no database: it only reads SQLite files and writes bundles.
  """
  use Boundary, top_level?: true, deps: [Aerox.Interop, Aerox.PDS]
  use Mix.Task
  alias Aerox.Interop.Bundle.Crypto
  alias Aerox.Interop.ReferencePds

  @switches [
    data: :string,
    out: :string,
    did: :keep,
    blobs: :string,
    host: :string,
    pds_version: :string,
    takeover: :boolean,
    recipient: :keep,
    passphrase_env: :string,
    insecure_plaintext: :boolean
  ]

  @impl true
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")
    data = opts[:data] || Mix.raise("--data <dir> is required")
    out = opts[:out] || Mix.raise("--out <dir> is required")
    recipients = recipients!(opts)

    if recipients == [] and not Keyword.get(opts, :insecure_plaintext, false),
      do:
        Mix.raise(
          "refusing to write plaintext bundles: give --recipient / --passphrase-env, or --insecure-plaintext"
        )

    Mix.Task.run("app.config", [])
    Enum.each([:crypto, :jose, :ex_secp256k1, :exqlite], &Application.ensure_all_started/1)
    our_host = Aerox.PDS.Config.hostname()

    accounts = ReferencePds.list_accounts(data)
    wanted = Keyword.get_values(opts, :did)
    accounts = if wanted == [], do: accounts, else: Enum.filter(accounts, &(&1.did in wanted))

    if accounts == [],
      do:
        Mix.raise(
          "no accounts selected from #{data} (#{length(ReferencePds.list_accounts(data))} in source)"
        )

    export_opts = [
      recipients: recipients,
      insecure_plaintext: Keyword.get(opts, :insecure_plaintext, false),
      takeover: Keyword.get(opts, :takeover, false),
      blobs_dir: opts[:blobs],
      host: opts[:host],
      pds_version: opts[:pds_version] || "unknown"
    ]

    results =
      for %{did: did} <- accounts do
        case ReferencePds.export(data, did, Path.join(out, did), export_opts) do
          {:ok, m} ->
            c = m["counts"]

            Mix.shell().info(
              "exported #{did} (#{c["records"]} records, #{c["blocks"]} blocks, #{c["blobs"]} blobs, #{c["seq_events"]} seq events)"
            )

            :ok

          {:error, reason} ->
            Mix.shell().error("FAILED #{did}: #{inspect(reason)}")
            :error
        end
      end

    failed = Enum.count(results, &(&1 == :error))

    Mix.shell().info(
      "#{length(results) - failed} exported, #{failed} failed, of #{length(accounts)} selected"
    )

    cond do
      opts[:host] == nil ->
        Mix.shell().info(
          "source hostname unknown (--host not given): every account may need a PLC #atproto_pds operation on import — list them with `mix aerox.bundle.import`; nothing is ever submitted (DESIGN §13.5)"
        )

      opts[:host] != our_host ->
        Mix.shell().info(
          "PLC operations needed on import into #{our_host} (NOT submitted — DESIGN §13.5):"
        )

        Enum.each(
          accounts,
          &Mix.shell().info(
            "  #{&1.did}: #atproto_pds https://#{opts[:host]} → https://#{our_host}"
          )
        )

      true ->
        Mix.shell().info("same hostname: no PLC operation needed")
    end

    if failed > 0, do: Mix.raise("export incomplete")
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
