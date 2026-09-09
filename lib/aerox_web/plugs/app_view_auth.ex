defmodule AeroxWeb.AppView.Auth do
  @moduledoc """
  The AppView's inbound auth (DESIGN §20.2): a service JWT from the caller's
  PDS (`iss` = the viewer's DID, `aud` = our service DID, `lxm` = the NSID),
  verified with the shared `Aerox.Auth.ServiceJWT` verifier through the
  AppView's identity cache. Sets `assigns.viewer` (a DID or nil). Requests
  without a token are anonymous; a bad token is refused.
  """
  import Plug.Conn
  alias Aerox.AppView.Config
  alias AeroxWeb.XRPC.Error

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      [] ->
        assign(conn, :viewer, nil)

      ["Bearer " <> token] ->
        nsid = AeroxWeb.XRPC.nsid(conn)

        resolver = fn iss, force ->
          Aerox.Identity.resolve_signing_key(
            Aerox.AppView.Identity,
            iss |> String.split("#") |> hd(),
            force: force
          )
        end

        case Aerox.Auth.ServiceJWT.verify(token, Config.service_did(), nsid, resolver) do
          {:ok, claims} ->
            assign(conn, :viewer, claims.iss |> String.split("#") |> hd())

          {:error, {name, msg}} ->
            AeroxWeb.Plugs.XRPCError.render(conn, Error.auth_required(msg, name))
        end

      _ ->
        AeroxWeb.Plugs.XRPCError.render(
          conn,
          Error.invalid_request("Unexpected authorization type", "InvalidToken")
        )
    end
  end
end
