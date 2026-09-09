defmodule Mix.Tasks.Aerox.Interop.ToPds do
  @shortdoc "Bundles → a reference-PDS <data> directory for a pinned image version (MIX_ENV=tool)"
  @moduledoc """
  DESIGN §13.2 hand-back: writes bundles into a `<data>` directory that a
  stock `ghcr.io/bluesky-social/pds:<version>` boots from, including the
  Kysely migration rows that version expects.

      MIX_ENV=tool mix aerox.interop.to_pds --in <bundle-or-dir> --data <dir> --pds-version 0.4
          [--blobs <dir>] [--takeover] [--host <target pds hostname>]
          [--recipient-key <jwk-or-pem>] [--passphrase-env VAR] [--expect-signer did:key:…]

  Accounts whose `#atproto_pds` would change (bundle `source.host` differs
  from `--host`) are listed as PLC operations; none is submitted (§13.5).
  Needs no database.
  """
  use Boundary, top_level?: true, deps: [Aerox.Interop]
  use Mix.Task
  alias Aerox.Interop.{Bundle, ReferencePds, Verify}
  alias Aerox.Interop.Bundle.Crypto

  @switches [
    in: :string,
    data: :string,
    pds_version: :string,
    blobs: :string,
    takeover: :boolean,
    host: :string,
    recipient_key: :string,
    passphrase_env: :string,
    expect_signer: :string
  ]

  @impl true
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")
    input = opts[:in] || Mix.raise("--in <dir> is required")
    data = opts[:data] || Mix.raise("--data <dir> is required")

    version =
      opts[:pds_version] ||
        Mix.raise("--pds-version is required (one of #{inspect(ReferencePds.Schema.versions())})")

    Mix.Task.run("app.config", [])
    Enum.each([:crypto, :jose, :ex_secp256k1, :exqlite], &Application.ensure_all_started/1)

    dirs = Bundle.discover(input)
    if dirs == [], do: Mix.raise("no bundle (manifest.json) found under #{input}")
    takeover? = Keyword.get(opts, :takeover, false)

    results =
      for dir <- dirs do
        with {:ok, bundle} <-
               Bundle.read(dir, secret: secret!(opts), expect_signer: opts[:expect_signer]),
             pre = Verify.bundle(bundle, takeover: takeover?),
             _ = Enum.each(Verify.format(pre), &Mix.shell().info(&1)),
             true <- pre.ok? || {:error, :bundle_verification},
             {:ok, r} <-
               ReferencePds.write(bundle, data,
                 pds_version: version,
                 blobs_dir: opts[:blobs],
                 takeover: takeover?
               ) do
          Mix.shell().info(
            "wrote #{r.did}: #{r.records} records, #{r.blocks} blocks, #{r.blobs} blobs, #{r.seq_events} seq events"
          )

          print_plc(bundle, opts[:host])
          {r.did, :imported}
        else
          {:error, reason} ->
            Mix.shell().error("FAIL #{dir}: #{inspect(reason)}")
            {Path.basename(dir), {:failed, reason}}
        end
      end

    case Verify.summary(results, length(dirs)) do
      {:ok, s} ->
        Mix.shell().info(
          "summary: #{s.imported} written of #{s.source_accounts}; boot #{version} on #{data} to verify (DESIGN §13.3)"
        )

      {:error, {_, s}} ->
        Mix.raise("#{s.failed} failed, #{s.imported} written of #{s.source_accounts}")
    end
  end

  defp print_plc(_bundle, nil),
    do:
      Mix.shell().info(
        "  target hostname unknown (--host not given): check whether #atproto_pds must change; nothing is submitted (DESIGN §13.5)"
      )

  defp print_plc(bundle, host) do
    case Verify.plc_ops_needed(bundle, host) do
      [] ->
        :ok

      ops ->
        Enum.each(
          ops,
          &Mix.shell().info(
            "  PLC operation needed (NOT submitted): #{&1.did} #{&1.change} #{&1.from} → #{&1.to}"
          )
        )
    end
  end

  defp secret!(opts) do
    cond do
      opts[:recipient_key] ->
        case Crypto.parse_jwk(opts[:recipient_key]) do
          {:ok, jwk} -> {:jwk, jwk}
          {:error, reason} -> Mix.raise("--recipient-key: #{inspect(reason)}")
        end

      opts[:passphrase_env] ->
        {:passphrase,
         System.get_env(opts[:passphrase_env]) ||
           Mix.raise("environment variable #{opts[:passphrase_env]} is not set")}

      true ->
        nil
    end
  end
end
