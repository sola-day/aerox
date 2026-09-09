defmodule Mix.Tasks.Aerox.Bundle.Import do
  @shortdoc "Import bundles into aerox_pds, verify them, and report (never submits PLC ops)"
  @moduledoc """
  DESIGN §13.0 / §13.2 / §13.3. `--in` is one bundle directory or a directory
  of them (an instance export).

      mix aerox.bundle.import --in <dir> [--takeover] [--recipient-key <jwk-or-pem>]
                              [--passphrase-env VAR] [--only did,…] [--force]
                              [--expect-signer did:key:…] [--password-env VAR]

    * `--recipient-key`: our **private** P-256 / X25519 key (PEM/JWK path or
      literal) to unwrap the content key; `--passphrase-env VAR` for a
      passphrase bundle.
    * `--takeover`: insert `seq.car` rows with their original seqs. **Stop
      the PDS first** — the sequencer reads `max(seq)` only at start.
    * `--only`: comma-separated DIDs to import (the rest are ignored).
    * `--force`: re-import accounts whose progress row says done.
    * `--expect-signer`: refuse bundles not signed by this `did:key`.
    * `--password-env VAR`: run the login check with the password in `VAR`
      (a test account's; never on the command line).

  Every account is verified before (bundle) and after (database) import;
  the run exits non-zero when any account fails or when nothing was
  imported from a non-empty source (VERIFICATION §8, §9). Accounts whose
  `#atproto_pds` would change are listed as PLC operations to run
  separately — this task never submits one (§13.5).
  """
  use Boundary, top_level?: true, deps: [Aerox.Interop, Aerox.PDS]
  use Mix.Task
  alias Aerox.Interop.{Bundle, Runtime, Verify}
  alias Aerox.Interop.Bundle.{Crypto, Postgres}

  @switches [
    in: :string,
    takeover: :boolean,
    recipient_key: :string,
    passphrase_env: :string,
    only: :string,
    force: :boolean,
    expect_signer: :string,
    password_env: :string
  ]

  @impl true
  def run(args) do
    {opts, _, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")
    input = opts[:in] || Mix.raise("--in <dir> is required")
    secret = secret!(opts)
    takeover? = Keyword.get(opts, :takeover, false)
    only = opts[:only] && opts[:only] |> String.split(",", trim: true) |> MapSet.new()

    Runtime.start()
    if takeover?, do: Runtime.info("takeover mode: the PDS must be stopped while this runs")

    dirs = Bundle.discover(input)
    if dirs == [], do: Mix.raise("no bundle (manifest.json) found under #{input}")
    our_host = Aerox.PDS.Config.hostname()
    password = opts[:password_env] && System.get_env(opts[:password_env])

    results =
      for dir <- dirs do
        case Bundle.read(dir, secret: secret, expect_signer: opts[:expect_signer]) do
          {:error, reason} ->
            Runtime.error("FAIL #{dir}: cannot open bundle: #{inspect(reason)}")
            {Path.basename(dir), {:failed, reason}}

          {:ok, bundle} ->
            did = bundle.manifest["did"]

            if only && not MapSet.member?(only, did) do
              nil
            else
              import_one(bundle, did, takeover?, password, our_host, opts)
            end
        end
      end
      |> Enum.reject(&is_nil/1)

    case Verify.summary(results, length(dirs)) do
      {:ok, s} ->
        Runtime.info(
          "summary: #{s.imported} imported, #{s.skipped} already present, 0 failed, of #{s.source_accounts} in source"
        )

      {:error, {:nothing_imported, s}} ->
        Mix.raise(
          "nothing imported from a non-empty source (#{s.source_accounts} bundles) — refusing to report success"
        )

      {:error, {:empty_source, _}} ->
        Mix.raise("the source holds no accounts")

      {:error, {:failures, s}} ->
        Mix.raise(
          "#{s.failed} account(s) failed: #{inspect(Enum.map(s.failed_dids, &elem(&1, 0)))}"
        )
    end
  end

  defp import_one(bundle, did, takeover?, password, our_host, opts) do
    pre = Verify.bundle(bundle, takeover: takeover?)
    Enum.each(Verify.format(pre), &Runtime.info/1)

    if pre.ok? do
      case Postgres.import(bundle, takeover: takeover?, force: Keyword.get(opts, :force, false)) do
        {:ok, :skipped} ->
          Runtime.info("skip  #{did}: already imported and present")
          {did, :skipped}

        {:ok, _report} ->
          post = Verify.imported(did, bundle, takeover: takeover?, password: password)
          Enum.each(Verify.format(post), &Runtime.info/1)
          print_plc(Verify.plc_ops_needed(bundle, our_host))
          if post.ok?, do: {did, :imported}, else: {did, {:failed, :post_import_verification}}

        {:error, reason} ->
          Runtime.error("FAIL #{did}: #{inspect(reason)}")
          {did, {:failed, reason}}
      end
    else
      {did, {:failed, :bundle_verification}}
    end
  end

  defp print_plc([]), do: :ok

  defp print_plc(ops) do
    Runtime.info(
      "PLC operations needed (NOT submitted — DESIGN §13.5; run the separate, safeguarded PLC step):"
    )

    Enum.each(ops, &Runtime.info("  #{&1.did}: #{&1.change} #{&1.from} → #{&1.to}"))
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
