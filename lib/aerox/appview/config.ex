defmodule Aerox.AppView.Config do
  @moduledoc "AppView settings from `config :aerox, Aerox.AppView` (DESIGN §15, §16)."

  def all, do: Application.get_env(:aerox, Aerox.AppView, [])
  def get(key, default \\ nil), do: Keyword.get(all(), key, default)

  @doc "The hostname the AppView (and the image CDN under /img) answers on."
  def hostname, do: get(:hostname) || "appview.localhost"
  def public_url, do: get(:public_url) || "https://" <> hostname()
  def service_did, do: get(:service_did) || "did:web:" <> hostname()
  @doc "The Relay the ingest subscribes to (DESIGN §15.1: never the PDS directly)."
  def relay_url, do: get(:relay_url) || "wss://relay.localhost"

  # Processor partitions of the ingest pipeline (DESIGN §21.5). Events of one
  # repo stay in one partition, so this is the parallelism across repos and
  # the axis VERIFICATION §10.1 asks to measure ingest throughput along.
  def ingest_concurrency, do: get(:ingest_concurrency) || 4
  @doc "Image CDN base for view URLs (DESIGN §16); defaults to `<public_url>/img`."
  def image_url, do: get(:image_url) || public_url() <> "/img"

  @doc "Labelers this AppView subscribes to (DESIGN §15.6): `[%{did:, url:}]`, entries without a DID dropped."
  def labelers do
    for %{did: did, url: url} <- get(:labelers, []) || [],
        is_binary(did),
        is_binary(url),
        do: %{did: did, url: url}
  end

  @doc "Labelers applied by default (DESIGN §15.6): the configured set, else every subscribed labeler."
  def default_labelers, do: get(:default_labelers) || Enum.map(labelers(), & &1.did)

  @doc "The AppView's own signing keypair (K256), used for outbound service JWTs (feed generators, DESIGN §15.4)."
  def signing_keypair do
    hex =
      get(:signing_key_hex) || raise("config :aerox, Aerox.AppView, signing_key_hex: is required")

    Aerox.ATProto.Crypto.import(:k256, hex)
  end

  @doc "Image cache directory (DESIGN §16)."
  def image_cache_dir, do: get(:image_cache_dir) || "tmp/image-cache"
end
