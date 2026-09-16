# Shared setup for the labeler tests: `Code.require_file("helpers.exs", __DIR__)`.
unless Code.ensure_loaded?(Aerox.LabelerTestHelpers) do
  defmodule Aerox.LabelerTestHelpers do
    @moduledoc """
    The labeler account for a test (`Aerox.Labeler.Setup.ensure_account!/1`
    against the sandboxed PDS and PLC) and the runtime configuration that
    follows from its DID: `Aerox.Labeler` (did, key), `Aerox.PDS`
    (`mod_service`, `mod_service_did`, the proxy routed through the
    Endpoint), `Aerox.AppView` (`default_labelers`). Everything is restored
    on exit.
    """
    import ExUnit.Callbacks, only: [on_exit: 1]

    @handle "labeler.aerox.sola.town"
    @password "labeler-pw-pw"

    def handle, do: @handle

    @doc "Creates the labeler account and configures every service for it; returns `%{did, handle, signing_key_hex}`."
    def ensure_labeler! do
      Aerox.RateLimit.reset()
      labeler = Aerox.Labeler.Setup.ensure_account!(handle: @handle, password: @password)
      configure!(labeler.did, labeler.signing_key_hex)
      labeler
    end

    @doc "Configures the services for a labeler DID and key without creating an account (pure unit tests)."
    def configure!(did, key_hex) do
      originals =
        for app <- [Aerox.Labeler, Aerox.PDS, Aerox.AppView],
            do: {app, Application.get_env(:aerox, app, [])}

      Application.put_env(
        :aerox,
        Aerox.Labeler,
        Keyword.merge(Application.get_env(:aerox, Aerox.Labeler, []),
          did: did,
          signing_key_hex: key_hex
        )
      )

      Application.put_env(
        :aerox,
        Aerox.PDS,
        Keyword.merge(Application.get_env(:aerox, Aerox.PDS, []),
          mod_service: [url: Aerox.Labeler.Config.public_url(), did: did],
          mod_service_did: did,
          proxy_plug: AeroxWeb.Endpoint
        )
      )

      Application.put_env(
        :aerox,
        Aerox.AppView,
        Keyword.merge(Application.get_env(:aerox, Aerox.AppView, []), default_labelers: [did])
      )

      on_exit(fn ->
        for {app, original} <- originals, do: Application.put_env(:aerox, app, original)
        for key <- ["did", "signing_key_hex"], do: Aerox.Labeler.Settings.forget(key)
      end)

      :ok
    end

    @doc "A throwaway labeler identity for tests that never touch the PDS."
    def configure_unit_labeler! do
      keypair = Aerox.ATProto.Crypto.generate(:k256)
      did = "did:plc:" <> String.duplicate("l", 24)
      configure!(did, Base.encode16(keypair.private, case: :lower))
      %{did: did, keypair: keypair, did_key: Aerox.ATProto.Crypto.did_key(keypair)}
    end

    @doc "HTTP Basic credentials for the labeler admin API."
    def admin_auth, do: "Basic " <> Base.encode64("admin:admin-for-tests-labeler")

    @doc "A service JWT a PDS would mint for `did` calling `nsid` on the labeler."
    def service_jwt(did, nsid, aud \\ nil) do
      Aerox.Auth.ServiceJWT.create(
        keypair: Aerox.PDS.Accounts.signing_keypair(did),
        iss: did,
        aud: aud || Aerox.Labeler.Config.did(),
        lxm: nsid
      )
    end
  end
end
