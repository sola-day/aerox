defmodule AeroxWeb.Plugs.Auth do
  @moduledoc """
  Parses the Authorization header (upstream `auth-verifier.ts`) into
  `conn.assigns.auth`:

  * `Bearer <at+jwt>` → `%{type: :access, did, scope, token}`
  * `Bearer <refresh+jwt>` → `%{type: :refresh, did, token_id}`
  * `Bearer <service jwt>` (ES256K/ES256, `iss` a DID) → `%{type: :service, did, lxm}`
  * `Basic admin:<password>` → `%{type: :admin}`
  * `DPoP …` → left for the OAuth verifier (M4)
  * none → `nil`

  A malformed or expired token is an error immediately; which kinds a route
  accepts is decided by `AeroxWeb.XRPC.require_auth!/2` in the handler.
  """
  @behaviour Plug
  import Plug.Conn
  alias Aerox.PDS.{Config, Sessions}
  alias AeroxWeb.XRPC.Error

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      [] ->
        assign(conn, :auth, nil)

      ["Bearer " <> token] ->
        bearer(conn, String.trim(token))

      ["bearer " <> token] ->
        bearer(conn, String.trim(token))

      ["Basic " <> creds] ->
        basic(conn, creds)

      ["DPoP " <> _] ->
        assign(conn, :auth, %{type: :dpop})

      _ ->
        AeroxWeb.Plugs.XRPCError.render(
          conn,
          Error.invalid_request("Unexpected authorization type", "InvalidToken")
        )
    end
  end

  defp bearer(conn, token) do
    case header_typ(token) do
      "at+jwt" ->
        case Sessions.verify(token, "at+jwt") do
          {:ok, %{"sub" => did, "scope" => scope}} ->
            assign(conn, :auth, %{
              type: :access,
              did: did,
              scope: Sessions.scope_atom(scope),
              token: token
            })

          # upstream: InvalidRequestError (400) for both, so entryway proxies map cleanly
          {:error, :expired_token} ->
            AeroxWeb.Plugs.XRPCError.render(
              conn,
              Error.invalid_request("Token has expired", "ExpiredToken")
            )

          {:error, _} ->
            AeroxWeb.Plugs.XRPCError.render(
              conn,
              Error.invalid_request("Token could not be verified", "InvalidToken")
            )
        end

      "refresh+jwt" ->
        case Sessions.verify(token, "refresh+jwt") do
          {:ok, %{"sub" => did, "jti" => jti}} ->
            assign(conn, :auth, %{type: :refresh, did: did, token_id: jti})

          # upstream: InvalidRequestError (400) for both, so entryway proxies map cleanly
          {:error, :expired_token} ->
            AeroxWeb.Plugs.XRPCError.render(
              conn,
              Error.invalid_request("Token has expired", "ExpiredToken")
            )

          {:error, _} ->
            AeroxWeb.Plugs.XRPCError.render(
              conn,
              Error.invalid_request("Token could not be verified", "InvalidToken")
            )
        end

      :not_a_jwt ->
        AeroxWeb.Plugs.XRPCError.render(
          conn,
          Error.invalid_request("Token could not be verified", "InvalidToken")
        )

      _ ->
        service(conn, token)
    end
  end

  defp header_typ(token) do
    with [h, _, _] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(h, padding: false),
         {:ok, header} when is_map(header) <- Jason.decode(json) do
      header["typ"]
    else
      _ -> :not_a_jwt
    end
  end

  # Service JWT: iss resolved through the PDS's identity cache; aud must be
  # this service; lxm must be the route's NSID (createAccount excepted).
  defp service(conn, token) do
    nsid = AeroxWeb.XRPC.nsid(conn)
    lxm = if nsid == "com.atproto.server.createAccount", do: nil, else: nsid

    resolver = fn iss, force ->
      Aerox.Identity.resolve_signing_key(Aerox.PDS.Identity, iss |> String.split("#") |> hd(),
        force: force
      )
    end

    case Aerox.Auth.ServiceJWT.verify(token, Config.service_did(), lxm, resolver) do
      {:ok, claims} ->
        assign(conn, :auth, %{
          type: :service,
          did: claims.iss |> String.split("#") |> hd(),
          lxm: claims.lxm
        })

      {:error, {name, msg}} ->
        AeroxWeb.Plugs.XRPCError.render(conn, Error.auth_required(msg, name))
    end
  end

  defp basic(conn, creds) do
    with {:ok, decoded} <- Base.decode64(creds),
         ["admin", password] <- String.split(decoded, ":", parts: 2),
         admin when is_binary(admin) <- Config.get(:admin_password),
         true <- Plug.Crypto.secure_compare(password, admin) do
      assign(conn, :auth, %{type: :admin})
    else
      _ -> AeroxWeb.Plugs.XRPCError.render(conn, Error.auth_required())
    end
  end
end
