defmodule Aerox.PDS.Config do
  @moduledoc """
  The PDS's configuration, read from `config :aerox, Aerox.PDS`. Keys:

  * `:public_url` — the externally reachable https URL (clients read it back
    as the service endpoint; the endpoint's `url` config is the default)
  * `:service_did` — `did:web:<host>` by default
  * `:handle_domains` — `[".aerox.sola.town"]`; handles are hosted under these
  * `:plc_url` — the PLC directory this PDS registers accounts with
  * `:invites_required`, `:contact_email`, `:privacy_policy_url`, `:terms_of_service_url`
  * `:jwt_secret` — HS256 key for access/refresh tokens
  * `:recovery_did_key` — the offline recovery key at rotation index 1 (§14.2)
  * `:accepting_imports`, `:max_import_bytes`, `:blob_upload_limit`
  """

  @spec get(atom, term) :: term
  def get(key, default \\ nil), do: Keyword.get(all(), key, default)

  @spec all() :: keyword
  def all, do: Application.get_env(:aerox, Aerox.PDS, [])

  def public_url do
    get(:public_url) ||
      (
        url = Application.get_env(:aerox, AeroxWeb.Endpoint, [])[:url] || []
        scheme = url[:scheme] || "http"
        host = url[:host] || "localhost"
        port = url[:port] || 4000
        default_port? = (scheme == "https" and port == 443) or (scheme == "http" and port == 80)
        "#{scheme}://#{host}#{if default_port?, do: "", else: ":#{port}"}"
      )
  end

  def hostname, do: URI.parse(public_url()).host

  def service_did, do: get(:service_did) || "did:web:" <> hostname()

  def handle_domains, do: get(:handle_domains) || ["." <> hostname()]

  def plc_url,
    do: get(:plc_url) || Application.get_env(:aerox, :plc_url) || "https://plc.directory"

  def invites_required?, do: get(:invites_required, false)

  def jwt_secret do
    get(:jwt_secret) || Application.fetch_env!(:aerox, AeroxWeb.Endpoint)[:secret_key_base]
  end

  def recovery_did_key, do: get(:recovery_did_key)

  def accepting_imports?, do: get(:accepting_imports, true)

  def max_import_bytes, do: get(:max_import_bytes, 100 * 1024 * 1024)

  def blob_upload_limit, do: get(:blob_upload_limit, 50 * 1024 * 1024)

  def contact_email, do: get(:contact_email)

  def privacy_policy_url, do: get(:privacy_policy_url)

  def terms_of_service_url, do: get(:terms_of_service_url)

  def appview, do: get(:appview)

  def crawlers, do: get(:crawlers, [])

  @doc "The service signing key as a `did:key` (the `#atproto` verification method of the service DID document)."
  def signer_did_key, do: Aerox.Crypto.Signer.did_key(signer())

  @doc "The instance rotation key signer (DESIGN §14.2), built from `config :aerox, Aerox.Crypto.Signer`."
  def signer do
    case :persistent_term.get({__MODULE__, :signer}, nil) do
      nil ->
        config =
          Application.get_env(:aerox, Aerox.Crypto.Signer, adapter: Aerox.Crypto.Signer.Local)

        Aerox.Crypto.Signer.check_config!(config, Application.get_env(:aerox, :env, :dev))
        signer = Aerox.Crypto.Signer.from_config(config)
        :persistent_term.put({__MODULE__, :signer}, signer)
        signer

      signer ->
        signer
    end
  end

  @doc """
  The signer, or the reason it cannot be built.

  `signer/0` is lazy and building the `Remote` adapter *asks the signing
  service for its `did:key`* so it can pin it, so the first PLC operation after
  a restart is the one that discovers the service is down — and it discovers it
  as a raise from inside the HTTP client, several frames below anything that
  knows what to tell the caller. Call sites that can report an upstream failure
  use this instead.
  """
  @spec fetch_signer() :: {:ok, Aerox.Crypto.Signer.signer()} | {:error, term}
  def fetch_signer do
    {:ok, signer()}
  rescue
    e -> {:error, e}
  end

  @doc """
  Drops the cached signer, so the next call rebuilds it from configuration.
  It is cached in `:persistent_term` because every PLC operation reads it;
  without this there is no way to point the node at a moved signing service, or
  to swap the adapter in a test, short of a restart.
  """
  def reset_signer, do: :persistent_term.erase({__MODULE__, :signer})
end
