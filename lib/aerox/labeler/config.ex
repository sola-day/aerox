defmodule Aerox.Labeler.Config do
  @moduledoc "Labeler settings from `config :aerox, Aerox.Labeler` (DESIGN §17)."
  def all, do: Application.get_env(:aerox, Aerox.Labeler, [])
  def get(key, default \\ nil), do: Keyword.get(all(), key, default)
  def hostname, do: get(:hostname) || "labeler.localhost"
  def public_url, do: get(:public_url) || "https://" <> hostname()

  @doc "The labeler's own DID: the atproto account on our PDS that holds the app.bsky.labeler.service record (DESIGN §17.1)."
  def did, do: get(:did)
end
