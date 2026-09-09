defmodule AeroxWeb.WellKnown.WellKnownController do
  @moduledoc "`/.well-known/atproto-did` for hosted handles (DESIGN §20.1) and `/.well-known/did.json` for the service DID (§11.1)."
  use AeroxWeb, :controller
  alias Aerox.PDS.{Accounts, Config, Handle}

  def atproto_did(conn, _) do
    handle = conn.host

    with true <- Handle.service_domain?(handle) or handle == Config.hostname(),
         %{did: did} <- Accounts.get_account(handle) do
      conn |> put_resp_content_type("text/plain") |> send_resp(200, did)
    else
      _ -> conn |> put_resp_content_type("text/plain") |> send_resp(404, "User not found")
    end
  end

  def did_json(conn, _) do
    did = Config.service_did()

    doc = %{
      "@context" => ["https://www.w3.org/ns/did/v1", "https://w3id.org/security/multikey/v1"],
      "id" => did,
      "verificationMethod" => [
        %{
          "id" => did <> "#atproto",
          "type" => "Multikey",
          "controller" => did,
          "publicKeyMultibase" => Config.signer_did_key() |> String.replace_prefix("did:key:", "")
        }
      ],
      "service" => [
        %{
          "id" => "#atproto_pds",
          "type" => "AtprotoPersonalDataServer",
          "serviceEndpoint" => Config.public_url()
        }
      ]
    }

    conn
    |> put_resp_content_type("application/did+ld+json", nil)
    |> send_resp(200, Jason.encode!(doc))
  end
end
