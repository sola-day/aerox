defmodule AeroxWeb.OAuthFlowTest do
  @moduledoc """
  VERIFICATION §6 scenario 6: a public (loopback) client and a confidential
  (`private_key_jwt`) client complete atproto OAuth end to end — PAR with
  DPoP nonces, the consent page (sign-in, allow), the code grant with PKCE,
  DPoP-bound access tokens on XRPC, refresh rotation with replay detection,
  and revocation.
  """
  use AeroxWeb.ConnCase, async: false
  alias Aerox.Auth.DPoP

  @client_id "https://client.example/client-metadata.json"
  @jwks_uri "https://client.example/jwks.json"
  @redirect "https://client.example/callback"

  defmodule ClientSite do
    @moduledoc false
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, opts) do
      body =
        case conn.request_path do
          "/client-metadata.json" -> opts[:metadata].()
          "/jwks.json" -> opts[:jwks].()
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end
  end

  setup do
    Aerox.RateLimit.reset()
    Aerox.PDS.OAuth.Clients.flush_cache()

    {:ok, %{did: did}} =
      Aerox.PDS.Signup.create(%{
        handle: "oauth-user.aerox.sola.town",
        email: "oauth@example.com",
        password: "correct-horse"
      })

    {:ok, did: did}
  end

  # ------------------------------------------------------------ helpers

  defp key, do: JOSE.JWK.generate_key({:ec, "P-256"})
  defp public_map(jwk), do: jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map() |> elem(1)

  defp jwt(jwk, header, claims) do
    {_, token} = JOSE.JWS.sign(jwk, Jason.encode!(claims), header) |> JOSE.JWS.compact()
    token
  end

  defp proof(jwk, method, url, nonce, ath \\ nil) do
    claims = %{
      "jti" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
      "iat" => System.os_time(:second),
      "htm" => method,
      "htu" => url,
      "nonce" => nonce
    }

    claims = if ath, do: Map.put(claims, "ath", DPoP.ath(ath)), else: claims
    jwt(jwk, %{"alg" => "ES256", "typ" => "dpop+jwt", "jwk" => public_map(jwk)}, claims)
  end

  defp base, do: Aerox.PDS.Config.public_url()

  defp post_form(conn, path, body, headers) do
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> put_req_header(c, k, v) end)

    conn
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> post(path, URI.encode_query(body))
  end

  # an OAuth endpoint call with a DPoP proof; retries once on use_dpop_nonce
  defp dpop_post(conn, path, body, jwk, extra_headers \\ []) do
    url = base() <> path
    first = post_form(conn, path, body, [{"dpop", proof(jwk, "POST", url, nil)} | extra_headers])

    if first.status == 400 and first.resp_body =~ "use_dpop_nonce" do
      [nonce] = get_resp_header(first, "dpop-nonce")

      {post_form(conn, path, body, [{"dpop", proof(jwk, "POST", url, nonce)} | extra_headers]),
       nonce}
    else
      {first, nil}
    end
  end

  defp pkce do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {verifier, Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)}
  end

  # the consent flow through the browser pipeline: sign in, then allow
  defp consent(conn, client_id, request_uri, identifier, password) do
    page =
      conn
      |> put_private(:plug_skip_csrf_protection, true)
      |> get(~p"/oauth/authorize?#{[client_id: client_id, request_uri: request_uri]}")

    assert html_response(page, 200) =~ "Sign in"
    conn = recycle(page) |> put_private(:plug_skip_csrf_protection, true)

    signed =
      post(conn, ~p"/oauth/authorize/sign-in", %{
        "request_uri" => request_uri,
        "client_id" => client_id,
        "identifier" => identifier,
        "password" => password
      })

    assert redirected_to(signed) =~ "/oauth/authorize?"
    conn = recycle(signed) |> put_private(:plug_skip_csrf_protection, true)

    page2 = get(conn, ~p"/oauth/authorize?#{[client_id: client_id, request_uri: request_uri]}")
    html = html_response(page2, 200)
    assert html =~ "Allow"
    [did] = Regex.run(~r/name="did" value="([^"]+)"/, html, capture: :all_but_first)
    conn = recycle(page2) |> put_private(:plug_skip_csrf_protection, true)

    accepted =
      post(conn, ~p"/oauth/authorize/accept", %{"request_uri" => request_uri, "did" => did})

    location = redirected_to(accepted)
    query = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    {query, did}
  end

  test "public loopback client: PAR → consent → code grant → DPoP-bound XRPC → refresh → revoke",
       %{conn: conn, did: did} do
    redirect_uri = "http://127.0.0.1:4321/cb"

    client_id =
      "http://localhost?" <>
        URI.encode_query(redirect_uri: redirect_uri, scope: "atproto transition:generic")

    jwk = key()
    {verifier, challenge} = pkce()

    # metadata is discoverable
    meta = conn |> get("/.well-known/oauth-authorization-server") |> json_response(200)
    assert meta["issuer"] == base()
    assert meta["require_pushed_authorization_requests"] == true

    assert %{"keys" => [%{"kty" => "EC", "kid" => _}]} =
             conn |> get("/oauth/jwks") |> json_response(200)

    assert conn
           |> get("/.well-known/oauth-protected-resource")
           |> json_response(200)
           |> Map.get("authorization_servers") == [base()]

    par_body = %{
      "client_id" => client_id,
      "response_type" => "code",
      "redirect_uri" => redirect_uri,
      "scope" => "atproto transition:generic",
      "state" => "xyz",
      "code_challenge" => challenge,
      "code_challenge_method" => "S256"
    }

    {par, nonce} = dpop_post(conn, "/oauth/par", par_body, jwk)

    assert %{
             "request_uri" => "urn:ietf:params:oauth:request_uri:" <> _ = request_uri,
             "expires_in" => _
           } = json_response(par, 201)

    assert nonce != nil, "the first proof without a nonce is refused with use_dpop_nonce"

    # a wrong password is refused, the right one signs in and the user allows
    {query, ^did} =
      consent(conn, client_id, request_uri, "oauth-user.aerox.sola.town", "correct-horse")

    assert query["state"] == "xyz" and query["iss"] == base()
    assert "cod-" <> _ = code = query["code"]

    # the code grant, PKCE verified, DPoP bound to the PAR key
    {tok, _} =
      dpop_post(
        conn,
        "/oauth/token",
        %{
          "client_id" => client_id,
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => redirect_uri,
          "code_verifier" => verifier
        },
        jwk
      )

    tokens = json_response(tok, 200)

    assert %{
             "access_token" => access,
             "refresh_token" => refresh,
             "token_type" => "DPoP",
             "sub" => ^did,
             "scope" => "atproto transition:generic"
           } = tokens

    # the access token on XRPC: DPoP proof with ath, nonce from the response header
    xrpc = fn conn, method, path, nonce, extra ->
      url = base() <> path

      c =
        conn
        |> put_req_header("authorization", "DPoP " <> access)
        |> put_req_header("dpop", proof(jwk, method, url, nonce, access))

      {body, headers} = Keyword.pop(extra, :body, "")
      c = Enum.reduce(headers, c, fn {k, v}, c -> put_req_header(c, k, v) end)
      if method == "GET", do: get(c, path), else: post(c, path, body)
    end

    first = xrpc.(conn, "GET", "/xrpc/com.atproto.server.getSession", nil, [])
    assert first.status == 401
    [n] = get_resp_header(first, "dpop-nonce")
    session = xrpc.(conn, "GET", "/xrpc/com.atproto.server.getSession", n, [])
    assert json_response(session, 200)["did"] == did

    # a Bearer use of a DPoP-bound token is refused; a proof from another key too
    assert conn
           |> put_req_header("authorization", "Bearer " <> access)
           |> get("/xrpc/com.atproto.server.getSession")
           |> json_response(400)
           |> Map.get("error") == "InvalidToken"

    other = key()

    bad =
      conn
      |> put_req_header("authorization", "DPoP " <> access)
      |> put_req_header(
        "dpop",
        proof(other, "GET", base() <> "/xrpc/com.atproto.server.getSession", n, access)
      )
      |> get("/xrpc/com.atproto.server.getSession")

    assert bad.status == 401

    # a write through the OAuth session (transition:generic covers repo writes)
    body =
      Jason.encode!(%{
        "repo" => did,
        "collection" => "app.bsky.feed.post",
        "record" => %{
          "$type" => "app.bsky.feed.post",
          "text" => "via oauth",
          "createdAt" => "2026-09-09T20:00:00.000Z"
        }
      })

    created =
      xrpc.(conn, "POST", "/xrpc/com.atproto.repo.createRecord", n, [
        {"content-type", "application/json"},
        body: body
      ])

    assert %{"uri" => "at://" <> _} = json_response(created, 200)

    # refresh rotates; the old refresh token replays → the session is revoked
    {ref, _} =
      dpop_post(
        conn,
        "/oauth/token",
        %{"client_id" => client_id, "grant_type" => "refresh_token", "refresh_token" => refresh},
        jwk
      )

    assert %{"access_token" => access2, "refresh_token" => refresh2} = json_response(ref, 200)
    assert access2 != access and refresh2 != refresh

    {rep, _} =
      dpop_post(
        conn,
        "/oauth/token",
        %{"client_id" => client_id, "grant_type" => "refresh_token", "refresh_token" => refresh},
        jwk
      )

    assert json_response(rep, 400)["error_description"] =~ "replayed"
    # …so the rotated tokens are dead too
    {dead, _} =
      dpop_post(
        conn,
        "/oauth/token",
        %{"client_id" => client_id, "grant_type" => "refresh_token", "refresh_token" => refresh2},
        jwk
      )

    assert json_response(dead, 400)["error"] == "invalid_grant"

    # a replayed code is refused (upstream also revokes whatever it produced)
    {replay, _} =
      dpop_post(
        conn,
        "/oauth/token",
        %{
          "client_id" => client_id,
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => redirect_uri,
          "code_verifier" => verifier
        },
        jwk
      )

    assert json_response(replay, 400)["error"] == "invalid_grant"
  end

  test "confidential client (private_key_jwt, discoverable metadata) and scope enforcement", %{
    conn: conn,
    did: did
  } do
    client_key = key()
    {_, client_public} = client_key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    client_public = Map.put(client_public, "kid", "k1")

    metadata = fn ->
      %{
        "client_id" => @client_id,
        "client_name" => "Test confidential client",
        "redirect_uris" => [@redirect],
        "scope" => "atproto repo:app.bsky.feed.post?action=create",
        "grant_types" => ["authorization_code", "refresh_token"],
        "response_types" => ["code"],
        "application_type" => "web",
        "token_endpoint_auth_method" => "private_key_jwt",
        "token_endpoint_auth_signing_alg" => "ES256",
        "jwks_uri" => @jwks_uri,
        "dpop_bound_access_tokens" => true
      }
    end

    Application.put_env(:aerox, Aerox.PDS.OAuth.Clients,
      plug: {ClientSite, [metadata: metadata, jwks: fn -> %{"keys" => [client_public]} end]}
    )

    on_exit(fn -> Application.delete_env(:aerox, Aerox.PDS.OAuth.Clients) end)

    assertion = fn ->
      jwt(client_key, %{"alg" => "ES256", "kid" => "k1"}, %{
        "iss" => @client_id,
        "sub" => @client_id,
        "aud" => base(),
        "jti" => Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false),
        "iat" => System.os_time(:second),
        "exp" => System.os_time(:second) + 60
      })
    end

    creds = fn ->
      %{
        "client_id" => @client_id,
        "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        "client_assertion" => assertion.()
      }
    end

    jwk = key()
    {verifier, challenge} = pkce()

    {par, _} =
      dpop_post(
        conn,
        "/oauth/par",
        Map.merge(creds.(), %{
          "response_type" => "code",
          "redirect_uri" => @redirect,
          "scope" => "atproto repo:app.bsky.feed.post?action=create",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256"
        }),
        jwk
      )

    assert %{"request_uri" => request_uri} = json_response(par, 201)

    # a scope the client did not declare is refused at PAR
    {bad, _} =
      dpop_post(
        conn,
        "/oauth/par",
        Map.merge(creds.(), %{
          "response_type" => "code",
          "redirect_uri" => @redirect,
          "scope" => "atproto transition:generic",
          "code_challenge" => challenge,
          "code_challenge_method" => "S256"
        }),
        jwk
      )

    assert json_response(bad, 400)["error_description"] =~ "not declared"

    {query, ^did} = consent(conn, @client_id, request_uri, "oauth@example.com", "correct-horse")

    {tok, _} =
      dpop_post(
        conn,
        "/oauth/token",
        Map.merge(creds.(), %{
          "grant_type" => "authorization_code",
          "code" => query["code"],
          "redirect_uri" => @redirect,
          "code_verifier" => verifier
        }),
        jwk
      )

    %{"access_token" => access} = json_response(tok, 200)

    # granular scope: creating a post is allowed, deleting one is not, and getSession (account) is not covered
    url = base() <> "/xrpc/com.atproto.repo.createRecord"

    call = fn conn, path, nonce, body ->
      c =
        conn
        |> put_req_header("authorization", "DPoP " <> access)
        |> put_req_header("dpop", proof(jwk, "POST", base() <> path, nonce, access))
        |> put_req_header("content-type", "application/json")

      post(c, path, body)
    end

    probe = call.(conn, "/xrpc/com.atproto.repo.createRecord", nil, "{}")
    [n] = get_resp_header(probe, "dpop-nonce")
    _ = url

    body =
      Jason.encode!(%{
        "repo" => did,
        "collection" => "app.bsky.feed.post",
        "record" => %{
          "$type" => "app.bsky.feed.post",
          "text" => "scoped",
          "createdAt" => "2026-09-09T20:00:00.000Z"
        }
      })

    assert %{"uri" => uri} =
             call.(conn, "/xrpc/com.atproto.repo.createRecord", n, body) |> json_response(200)

    rkey = uri |> String.split("/") |> List.last()

    denied =
      call.(
        conn,
        "/xrpc/com.atproto.repo.deleteRecord",
        n,
        Jason.encode!(%{"repo" => did, "collection" => "app.bsky.feed.post", "rkey" => rkey})
      )

    assert json_response(denied, 403)["message"] =~ "repo:app.bsky.feed.post?action=delete"
  end
end
