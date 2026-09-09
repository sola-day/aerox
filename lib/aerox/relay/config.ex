defmodule Aerox.Relay.Config do
  @moduledoc "Relay settings from `config :aerox, Aerox.Relay` (DESIGN §19)."

  def all, do: Application.get_env(:aerox, Aerox.Relay, [])
  def get(key, default \\ nil), do: Keyword.get(all(), key, default)

  @doc "The hostname the Relay answers on; requests to it are routed to `AeroxWeb.RelayRouter`."
  def hostname, do: get(:hostname) || "relay.localhost"
  def public_url, do: get(:public_url) || "https://" <> hostname()
  def service_did, do: get(:service_did) || "did:web:" <> hostname()

  @doc "Accounts a new, untrusted host may have before further accounts are throttled (indigo `DefaultRepoLimit`)."
  def default_account_limit, do: get(:default_account_limit, 100)
  def trusted_account_limit, do: get(:trusted_account_limit, 10_000_000)
  def trusted_domains, do: get(:trusted_domains, [])
  def allow_insecure_hosts?, do: get(:allow_insecure_hosts, false)
  def skip_account_host_check?, do: get(:skip_account_host_check, false)
  def lenient_sync_validation?, do: get(:lenient_sync_validation, false)
  @doc "Retention window for re-sequenced events (DESIGN §19: 72 h)."
  def retention_ms, do: get(:retention_hours, 72) * 3600 * 1000
  @doc "New hosts admitted per day through public requestCrawl."
  def new_hosts_per_day, do: get(:new_hosts_per_day, 50)
  @doc "Verification failures before a host is paused (status `throttled`)."
  def max_host_errors, do: get(:max_host_errors, 100)
  def admin_password, do: get(:admin_password)
end
