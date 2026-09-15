defmodule AeroxWeb.Plugs.StreamMethodsTest do
  @moduledoc "Event Stream spec, \"Connection\": 405 for a non-GET, 426 for a GET without an upgrade, on every stream."
  use AeroxWeb.ConnCase, async: false

  @streams [
    {"pds.aerox.sola.town", "com.atproto.sync.subscribeRepos"},
    {:relay, "com.atproto.sync.subscribeRepos"},
    {:labeler, "com.atproto.label.subscribeLabels"}
  ]

  defp host("pds" <> _ = h), do: h
  defp host(:relay), do: Aerox.Relay.Config.hostname()
  defp host(:labeler), do: Aerox.Labeler.Config.hostname()

  test "the subscription NSIDs come from the lexicons" do
    subs = AeroxWeb.Plugs.StreamMethods.subscriptions()
    assert "com.atproto.sync.subscribeRepos" in subs
    assert "com.atproto.label.subscribeLabels" in subs
    refute "com.atproto.sync.getRepo" in subs
  end

  for {h, nsid} <- @streams do
    test "#{nsid} on #{inspect(h)}", %{conn: conn} do
      conn = %{conn | host: host(unquote(h))}
      path = "/xrpc/" <> unquote(nsid)

      resp = post(conn, path)
      assert resp.status == 405
      assert get_resp_header(resp, "allow") == ["GET"]
      assert %{"error" => "InvalidRequest"} = Jason.decode!(resp.resp_body)

      resp = get(conn, path)
      assert resp.status == 426
      assert get_resp_header(resp, "upgrade") == ["websocket"]
      assert %{"error" => "InvalidRequest"} = Jason.decode!(resp.resp_body)

      # asks for an upgrade but leaves out the key: malformed, not "upgrade required"
      resp =
        conn
        |> put_req_header("connection", "Upgrade")
        |> put_req_header("upgrade", "websocket")
        |> get(path)

      assert resp.status == 400

      assert %{"error" => "InvalidRequest", "message" => "Invalid WebSocket upgrade" <> _} =
               Jason.decode!(resp.resp_body)
    end
  end

  test "other methods on a stream host are untouched", %{conn: conn} do
    conn = %{conn | host: "pds.aerox.sola.town"}
    assert post(conn, "/xrpc/com.atproto.sync.getRepo").status == 501
  end
end
