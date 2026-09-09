defmodule AeroxWeb.AppView.MetaController do
  @moduledoc "Health, the service DID document, and the 501 catch-all of the AppView host."
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  alias Aerox.AppView.Config
  alias AeroxWeb.XRPC.Error

  def home(conn, _), do: text(conn, "aerox appview (#{Config.hostname()})\n")
  def health(conn, _), do: respond(conn, %{"status" => "ok"})

  def did_json(conn, _) do
    respond(conn, %{
      "@context" => ["https://www.w3.org/ns/did/v1", "https://w3id.org/security/multikey/v1"],
      "id" => Config.service_did(),
      # the key our outbound service JWTs (feed generators) are signed with
      "verificationMethod" => [
        %{
          "id" => Config.service_did() <> "#atproto",
          "type" => "Multikey",
          "controller" => Config.service_did(),
          "publicKeyMultibase" =>
            Config.signing_keypair()
            |> Aerox.ATProto.Crypto.did_key()
            |> String.replace_prefix("did:key:", "")
        }
      ],
      "service" => [
        %{
          "id" => "#bsky_appview",
          "type" => "BskyAppView",
          "serviceEndpoint" => Config.public_url()
        }
      ]
    })
  end

  def get_config(conn, _), do: respond(conn, %{"checkEmailConfirmed" => false})

  def not_implemented(_conn, _), do: {:error, Error.not_implemented()}
end
