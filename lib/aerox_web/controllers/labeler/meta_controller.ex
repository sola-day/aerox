defmodule AeroxWeb.Labeler.MetaController do
  @moduledoc "Health, the service DID document, and the 501 catch-all of the Labeler host."
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  alias Aerox.Labeler.Config
  alias AeroxWeb.XRPC.Error

  def health(conn, _), do: respond(conn, %{"status" => "ok"})

  def did_json(conn, _) do
    respond(conn, %{
      "@context" => ["https://www.w3.org/ns/did/v1"],
      "id" => "did:web:" <> Config.hostname(),
      "service" => [
        %{
          "id" => "#atproto_labeler",
          "type" => "AtprotoLabeler",
          "serviceEndpoint" => Config.public_url()
        }
      ]
    })
  end

  def not_implemented(_conn, _), do: {:error, Error.not_implemented()}
end
