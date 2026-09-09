defmodule AeroxWeb.PDS.ProxyTest do
  @moduledoc "DESIGN §11.1: app.bsky.* is forwarded to the configured AppView with a service JWT."
  use AeroxWeb.ConnCase, async: false
  alias Aerox.Auth.ServiceJWT

  setup do
    Aerox.RateLimit.reset()
    bypass = Bypass.open()
    original = Application.get_env(:aerox, Aerox.PDS)

    Application.put_env(
      :aerox,
      Aerox.PDS,
      Keyword.put(original, :appview,
        url: "http://localhost:#{bypass.port}",
        did: "did:web:appview.test"
      )
    )

    on_exit(fn -> Application.put_env(:aerox, Aerox.PDS, original) end)
    {:ok, bypass: bypass}
  end

  defp signup(conn, handle) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/xrpc/com.atproto.server.createAccount",
      Jason.encode!(%{
        "handle" => handle,
        "email" => "#{handle}@example.com",
        "password" => "pw-pw-pw-pw"
      })
    )
    |> json_response(200)
  end

  test "authenticated GET is forwarded with a service JWT the AppView can verify", %{
    conn: conn,
    bypass: bypass
  } do
    %{"did" => did, "accessJwt" => jwt} = signup(conn, "proxied.test")
    key = Aerox.PDS.Accounts.signing_keypair(did)
    did_key = Aerox.ATProto.Crypto.did_key(key)

    Bypass.expect_once(bypass, "GET", "/xrpc/app.bsky.feed.getTimeline", fn req ->
      assert req.query_string == "limit=5"
      assert ["Bearer " <> token] = Plug.Conn.get_req_header(req, "authorization")

      assert {:ok, %{iss: ^did, aud: "did:web:appview.test", lxm: "app.bsky.feed.getTimeline"}} =
               ServiceJWT.verify(
                 token,
                 "did:web:appview.test",
                 "app.bsky.feed.getTimeline",
                 fn _iss, _ -> {:ok, did_key} end
               )

      assert ["did:web:labeler.test"] = Plug.Conn.get_req_header(req, "atproto-accept-labelers")

      req
      |> Plug.Conn.put_resp_header("atproto-repo-rev", "3abc")
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"feed":[],"cursor":null}))
    end)

    resp =
      conn
      |> put_req_header("authorization", "Bearer " <> jwt)
      |> put_req_header("atproto-accept-labelers", "did:web:labeler.test")
      |> get("/xrpc/app.bsky.feed.getTimeline?limit=5")

    assert json_response(resp, 200) == %{"feed" => [], "cursor" => nil}
    assert ["3abc"] = get_resp_header(resp, "atproto-repo-rev")
  end

  test "unauthenticated GET is forwarded without authorization; POST bodies pass verbatim; upstream errors are relayed",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/xrpc/app.bsky.actor.getProfile", fn req ->
      assert [] = Plug.Conn.get_req_header(req, "authorization")

      req
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(400, ~s({"error":"InvalidRequest","message":"Profile not found"}))
    end)

    assert conn |> get("/xrpc/app.bsky.actor.getProfile?actor=x") |> json_response(400) == %{
             "error" => "InvalidRequest",
             "message" => "Profile not found"
           }

    Bypass.expect_once(bypass, "POST", "/xrpc/app.bsky.notification.updateSeen", fn req ->
      {:ok, body, req} = Plug.Conn.read_body(req)
      assert body == ~s({"seenAt":"2026-09-09T00:00:00.000Z"})
      Plug.Conn.resp(req, 200, "")
    end)

    assert conn
           |> put_req_header("content-type", "application/json")
           |> post(
             "/xrpc/app.bsky.notification.updateSeen",
             ~s({"seenAt":"2026-09-09T00:00:00.000Z"})
           )
           |> response(200)
  end

  test "explicit atproto-proxy to the configured AppView; protected methods refused; no target is 501",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(
      bypass,
      "GET",
      "/xrpc/app.bsky.feed.getFeed",
      &Plug.Conn.resp(&1, 200, "{}")
    )

    assert conn
           |> put_req_header("atproto-proxy", "did:web:appview.test#bsky_appview")
           |> get("/xrpc/app.bsky.feed.getFeed")
           |> response(200)

    assert conn
           |> put_req_header("atproto-proxy", "#bsky_appview")
           |> get("/xrpc/app.bsky.feed.getFeed")
           |> json_response(400)
           |> Map.get("message") == "no did specified in proxy header"

    assert conn
           |> get("/xrpc/chat.bsky.convo.listConvos")
           |> json_response(501)
           |> Map.get("error") == "MethodNotImplemented"
  end
end
