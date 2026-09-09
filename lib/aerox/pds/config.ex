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
end
