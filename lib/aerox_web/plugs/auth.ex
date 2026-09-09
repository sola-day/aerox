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

  @space_notify_methods ~w(com.atproto.space.notifyWrite com.atproto.space.notifySpaceDeleted)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      # tests inject a session directly (DESIGN §12 scenario tests); only
      # honoured when `config :aerox, Aerox.PDS.Space, trust_preassigned_auth: true`
      [] when is_map_key(conn.assigns, :auth) ->
        if Application.get_env(:aerox, Aerox.PDS.Space, [])[:trust_preassigned_auth] == true,
          do: conn,
          else: assign(conn, :auth, nil)

      [] ->
        assign(conn, :auth, nil)

      ["Bearer " <> token] ->
        bearer(conn, String.trim(token))

      ["bearer " <> token] ->
        bearer(conn, String.trim(token))

      ["Basic " <> creds] ->
        basic(conn, creds)

      # a space credential travels as `DPoP <credential>` with a proof
      # (bulletin's SpaceCredential.fetch) or as a plain Bearer
      ["DPoP " <> token] ->
        token = String.trim(token)

        if header_typ(token) == Aerox.PDS.Space.Credentials.credential_typ(),
          do: space_credential(conn, token, true),
          else: oauth(conn, "DPoP", token)

      _ ->
        AeroxWeb.Plugs.XRPCError.render(
          conn,
          Error.invalid_request("Unexpected authorization type", "InvalidToken")
        )
    end
  end

  defp bearer(conn, token) do
    case header_typ(token) do
      # OAuth access tokens are ES256 at+jwt from the issuer keyset; legacy
      # sessions are HS256 (DESIGN §11.2)
      "at+jwt" ->
        if header_alg(token) == "ES256",
          do: oauth(conn, "Bearer", token),
          else: legacy_access(conn, token)

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

      # Spaces (DESIGN §12.4, the published alpha): a space credential (always
      # DPoP-bound — a Bearer presentation still needs its proof) or a
      # delegation token, verified under the issuer's #atproto key
      "atproto-space-credential+jwt" ->
        space_credential(conn, token, true)

      "atproto-space-delegation+jwt" ->
        delegation(conn, token)

      _ ->
        service(conn, token)
    end
  end

  # The alpha's space credential verifier: the token itself, then the DPoP
  # proof over the request bound to it (`ath`) and signed by the key in its
  # `cnf.jkt` (upstream `verifyDpopProof` with `credential` and `jkt`).
  # Nonces are not required of these proofs (the alpha client sends none).
  defp space_credential(conn, token, dpop?) do
    with {:ok, cred} <- Aerox.PDS.Space.Credentials.verify_credential(token),
         {:ok, jkt} <- space_dpop(conn, token, dpop?),
         :ok <- check_cnf(cred, jkt) do
      assign(conn, :auth, %{
        type: :space_credential,
        iss: cred.iss,
        space: cred.sub,
        jkt: jkt,
        token: token
      })
    else
      {:error, msg} when is_binary(msg) ->
        AeroxWeb.Plugs.XRPCError.render(
          conn,
          Error.auth_required("Invalid space credential: #{msg}", "InvalidCredential")
        )

      {:error, {_, msg}} ->
        AeroxWeb.Plugs.XRPCError.render(
          conn,
          Error.auth_required("Invalid space credential: #{msg}", "InvalidCredential")
        )

      {:error, other} ->
        AeroxWeb.Plugs.XRPCError.render(
          conn,
          Error.auth_required("Invalid space credential: #{inspect(other)}", "InvalidCredential")
        )
    end
  end

  defp space_dpop(conn, token, _) do
    url = Aerox.PDS.Config.public_url() <> conn.request_path
    proof_header = conn |> get_req_header("dpop") |> List.first()

    case Aerox.Auth.DPoP.verify(proof_header, conn.method, url,
           access_token: token,
           nonces: false
         ) do
      {:ok, nil} -> {:error, "DPoP proof required"}
      {:ok, %{jkt: jkt}} -> {:ok, jkt}
      {:error, {:invalid_dpop_proof, msg}} -> {:error, msg}
      {:error, other} -> {:error, other}
    end
  end

  defp check_cnf(%{jkt: jkt}, jkt), do: :ok

  defp check_cnf(_, _),
    do: {:error, "DPoP proof is not signed by the key the credential is bound to"}

  # A delegation token (`getSpaceCredential`): the space host checks `sub`
  # and `aud` against the requested space in the handler.
  defp delegation(conn, token) do
    case Aerox.PDS.Space.Credentials.verify_delegation(token) do
      {:ok, d} ->
        assign(conn, :auth, %{type: :delegation, did: d.iss, sub: d.sub, aud: d.aud, jti: d.jti})

      {:error, {name, msg}} ->
        AeroxWeb.Plugs.XRPCError.render(
          conn,
          Error.auth_required("Invalid delegation token: #{msg}", name)
        )
    end
  end

  defp legacy_access(conn, token) do
    case Sessions.verify(token, "at+jwt") do
      {:ok, %{"sub" => did, "scope" => scope}} ->
        assign(conn, :auth, %{
          type: :access,
          did: did,
          scope: Sessions.scope_atom(scope),
          token: token
        })

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
  end

  # OAuth (DESIGN §11.2, upstream auth-verifier oauth()): DPoP proof over the
  # request + token, then the access token itself. Every response carries the
  # next DPoP nonce; a missing/stale nonce is a 401 with use_dpop_nonce.
  defp oauth(conn, scheme, token) do
    conn = with_dpop_nonce(conn)
    url = Aerox.PDS.Config.public_url() <> conn.request_path
    proof_header = conn |> get_req_header("dpop") |> List.first()

    with {:ok, proof} <-
           Aerox.Auth.DPoP.verify(proof_header, conn.method, url, access_token: token),
         {:ok, %{did: did, scope: scope} = info} <-
           Aerox.PDS.OAuth.verify_request(scheme, token, proof) do
      assign(conn, :auth, %{
        type: :oauth,
        did: did,
        scope: :oauth,
        permissions: Aerox.Auth.Scopes.grant(scope) |> resolve_space_scopes(did),
        token_id: info.token_id,
        client_id: info.client_id,
        token: token
      })
    else
      {:error, :use_dpop_nonce} ->
        conn
        |> put_resp_header("www-authenticate", Aerox.Auth.DPoP.www_authenticate(:use_dpop_nonce))
        |> AeroxWeb.Plugs.XRPCError.render(
          Error.auth_required("Authorization server requires nonce in DPoP proof", "UseDpopNonce")
        )

      {:error, {:invalid_dpop_proof, msg}} ->
        conn
        |> put_resp_header(
          "www-authenticate",
          Aerox.Auth.DPoP.www_authenticate({:invalid_dpop_proof, msg})
        )
        |> AeroxWeb.Plugs.XRPCError.render(Error.auth_required(msg, "InvalidToken"))

      {:error, {_, msg}} ->
        AeroxWeb.Plugs.XRPCError.render(conn, Error.invalid_request(msg, "InvalidToken"))
    end
  end

  @doc "Adds the `DPoP-Nonce` header (RFC 9449 §8.2) to a response."
  def with_dpop_nonce(conn) do
    case Process.whereis(Aerox.Auth.DPoP) do
      nil -> conn
      _ -> put_resp_header(conn, "dpop-nonce", Aerox.Auth.DPoP.next_nonce())
    end
  end

  defp header_alg(token) do
    with [h, _, _] <- String.split(token, "."),
         {:ok, json} <- Base.url_decode64(h, padding: false),
         {:ok, header} when is_map(header) <- Jason.decode(json) do
      header["alg"]
    else
      _ -> nil
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

    # Spaces notifications (DESIGN §12.5) are addressed to an account hosted
    # here (`aud` = the space owner / member DID), not to the service DID:
    # the audience is checked by the handler against its accounts.
    own_did = if nsid in @space_notify_methods, do: nil, else: Config.service_did()

    case Aerox.Auth.ServiceJWT.verify(token, own_did, lxm, resolver) do
      {:ok, claims} ->
        assign(conn, :auth, %{
          type: :service,
          did: claims.iss |> String.split("#") |> hd(),
          aud: claims.aud,
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

  # alpha `withResolvedAuthority` / `withDefaultCollections` at use time
  defp resolve_space_scopes(%{permissions: perms} = granted, did),
    do: %{granted | permissions: Aerox.Auth.Scopes.resolve_space(perms, did)}
end
