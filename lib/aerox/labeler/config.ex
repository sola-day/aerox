defmodule Aerox.Labeler.Config do
  @moduledoc """
  Labeler settings from `config :aerox, Aerox.Labeler` (DESIGN §17), with
  the two values the setup task persists in `labeler.setting` as the
  fallback: the labeler account's DID and its signing key. Keys:

  * `:hostname`, `:public_url` — the labeler host (`did:web:<hostname>` is
    accepted as a service-JWT audience beside the account DID)
  * `:did` — the labeler account on our PDS (`AEROX_LABELER_DID`); falls back
    to the persisted setting
  * `:signing_key_hex` — the K256 key labels and outbound service JWTs are
    signed with. Upstream ozone signs with the labeler account's repo
    signing key (the DID document's `#atproto` key, which the PDS verifies
    service JWTs against), so `Aerox.Labeler.Setup` persists that key and
    this value only overrides it (a labeler run apart from its PDS)
  * `:admin_password` — HTTP Basic `admin:<password>` for `aerox.moderation.*`
  * `:actions` — the `Aerox.Labeler.Actions` implementation
  * `:appview_moderation` — the module that applies takedowns to an AppView
    in the same node (`Aerox.AppView.Moderation`), or nil
  * `:label_values` — the values declared in `app.bsky.labeler.service`
  * `:backfill_window_ms` — how far back `subscribeLabels` cursors may reach
  """
  def all, do: Application.get_env(:aerox, Aerox.Labeler, [])
  def get(key, default \\ nil), do: Keyword.get(all(), key, default)
  def hostname, do: get(:hostname) || "labeler.localhost"
  def public_url, do: get(:public_url) || "https://" <> hostname()

  @doc "The labeler's own DID: the atproto account on our PDS that holds the app.bsky.labeler.service record (DESIGN §17.1)."
  def did, do: get(:did) || setting("did")

  @doc "The DIDs accepted as the audience of inbound service JWTs: the account DID and `did:web:<hostname>`."
  def service_dids, do: Enum.reject(Enum.uniq([did(), "did:web:" <> hostname()]), &is_nil/1)

  @doc "The labeler signing keypair (K256)."
  def signing_keypair do
    hex =
      get(:signing_key_hex) || setting("signing_key_hex") ||
        raise(
          "labeler signing key not configured: run `mix aerox.labeler.setup` or set config :aerox, Aerox.Labeler, signing_key_hex:"
        )

    Aerox.ATProto.Crypto.import(:k256, hex)
  end

  def admin_password, do: get(:admin_password)
  def actions, do: get(:actions) || Aerox.Labeler.Actions.Default
  def backfill_window_ms, do: get(:backfill_window_ms) || 7 * 24 * 3600 * 1000

  @doc "The label values this labeler declares (`app.bsky.labeler.service` policies)."
  def label_values, do: get(:label_values) || Aerox.Labeler.Policies.default_values()

  defp setting(key), do: Aerox.Labeler.Settings.get(key)
end
