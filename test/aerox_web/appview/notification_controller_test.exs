defmodule AeroxWeb.AppView.NotificationControllerTest do
  @moduledoc "app.bsky.notification.* and app.bsky.labeler.getServices on the AppView host (DESIGN §15.5, §15.6)."
  use AeroxWeb.ConnCase, async: false
  import Aerox.AppViewHelpers
  alias Aerox.PDS.Sequencer, as: PdsSeq

  setup %{conn: conn} do
    Aerox.RateLimit.reset()
    since = PdsSeq.current() || 0
    alice = signup("alice-nc")
    bob = signup("bob-nc")
    ingest_since(since)
    {:ok, conn: %{conn | host: Aerox.AppView.Config.hostname()}, alice: alice, bob: bob}
  end

  defp as_viewer(conn, did, nsid),
    do: put_req_header(conn, "authorization", "Bearer " <> service_jwt(did, nsid))

  defp post_json(conn, did, nsid, body) do
    conn
    |> as_viewer(did, nsid)
    |> put_req_header("content-type", "application/json")
    |> post("/xrpc/#{nsid}", Jason.encode!(body))
  end

  test "listNotifications, getUnreadCount and updateSeen", ctx do
    %{conn: conn, alice: alice, bob: bob} = ctx
    post = create(alice.did, "app.bsky.feed.post", %{"text" => "hello", "createdAt" => now()})
    write!(alice.did, [post])

    follow =
      create(bob.did, "app.bsky.graph.follow", %{"subject" => alice.did, "createdAt" => now()})

    like =
      create(bob.did, "app.bsky.feed.like", %{
        "subject" => %{"uri" => post.uri, "cid" => to_string(post.cid)},
        "createdAt" => now()
      })

    write!(bob.did, [follow])
    write!(bob.did, [like])

    reply =
      create(bob.did, "app.bsky.feed.post", %{
        "text" => "hi alice",
        "createdAt" => now(),
        "reply" => %{
          "root" => %{"uri" => post.uri, "cid" => to_string(post.cid)},
          "parent" => %{"uri" => post.uri, "cid" => to_string(post.cid)}
        }
      })

    write!(bob.did, [reply])

    assert conn |> get("/xrpc/app.bsky.notification.listNotifications") |> json_response(401)

    body =
      conn
      |> as_viewer(alice.did, "app.bsky.notification.listNotifications")
      |> get("/xrpc/app.bsky.notification.listNotifications")
      |> valid_json!("app.bsky.notification.listNotifications")

    assert Enum.map(body["notifications"], & &1["reason"]) == ["reply", "like", "follow"]
    [r, l, f] = body["notifications"]
    assert r["uri"] == reply.uri and r["record"]["text"] == "hi alice"
    assert r["reasonSubject"] == post.uri
    assert r["author"]["did"] == bob.did and r["author"]["handle"] == "bob-nc.aerox.sola.town"
    assert l["uri"] == like.uri and l["reasonSubject"] == post.uri
    assert f["uri"] == follow.uri and f["record"]["subject"] == alice.did
    assert body["priority"] == false
    refute Map.has_key?(body, "cursor")
    # never seen anything: upstream's hack marks the newest unread and the rest read
    assert is_binary(body["seenAt"])
    assert Enum.map(body["notifications"], & &1["isRead"]) == [false, true, true]

    # unread count
    assert conn
           |> as_viewer(alice.did, "app.bsky.notification.getUnreadCount")
           |> get("/xrpc/app.bsky.notification.getUnreadCount")
           |> valid_json!("app.bsky.notification.getUnreadCount") == %{"count" => 3}

    # paging
    page1 =
      conn
      |> as_viewer(alice.did, "app.bsky.notification.listNotifications")
      |> get("/xrpc/app.bsky.notification.listNotifications", limit: 2)
      |> valid_json!("app.bsky.notification.listNotifications")

    assert length(page1["notifications"]) == 2 and is_binary(page1["cursor"])

    page2 =
      conn
      |> as_viewer(alice.did, "app.bsky.notification.listNotifications")
      |> get("/xrpc/app.bsky.notification.listNotifications", limit: 2, cursor: page1["cursor"])
      |> valid_json!("app.bsky.notification.listNotifications")

    assert Enum.map(page2["notifications"], & &1["reason"]) == ["follow"]

    # reasons filter
    assert conn
           |> as_viewer(alice.did, "app.bsky.notification.listNotifications")
           |> get("/xrpc/app.bsky.notification.listNotifications", %{"reasons" => ["like"]})
           |> valid_json!("app.bsky.notification.listNotifications")
           |> Map.get("notifications")
           |> Enum.map(& &1["reason"]) == ["like"]

    # updateSeen flips isRead and zeroes the count
    seen_at = now()

    assert conn
           |> post_json(alice.did, "app.bsky.notification.updateSeen", %{"seenAt" => seen_at})
           |> response(200)

    body =
      conn
      |> as_viewer(alice.did, "app.bsky.notification.listNotifications")
      |> get("/xrpc/app.bsky.notification.listNotifications")
      |> valid_json!("app.bsky.notification.listNotifications")

    assert Enum.all?(body["notifications"], &(&1["isRead"] == true))

    assert body["seenAt"] ==
             seen_at
             |> Aerox.ATProto.Syntax.parse_datetime()
             |> elem(1)
             |> Aerox.ATProto.Syntax.format_datetime()

    assert conn
           |> as_viewer(alice.did, "app.bsky.notification.getUnreadCount")
           |> get("/xrpc/app.bsky.notification.getUnreadCount")
           |> valid_json!("app.bsky.notification.getUnreadCount") == %{"count" => 0}

    # a new repost after the seen mark is unread again
    repost =
      create(bob.did, "app.bsky.feed.repost", %{
        "subject" => %{"uri" => post.uri, "cid" => to_string(post.cid)},
        "createdAt" => now()
      })

    write!(bob.did, [repost])

    assert conn
           |> as_viewer(alice.did, "app.bsky.notification.getUnreadCount")
           |> get("/xrpc/app.bsky.notification.getUnreadCount")
           |> valid_json!("app.bsky.notification.getUnreadCount") == %{"count" => 1}

    body =
      conn
      |> as_viewer(alice.did, "app.bsky.notification.listNotifications")
      |> get("/xrpc/app.bsky.notification.listNotifications", limit: 1)
      |> valid_json!("app.bsky.notification.listNotifications")

    assert [%{"reason" => "repost", "isRead" => false, "uri" => repost_uri}] =
             body["notifications"]

    assert repost_uri == repost.uri

    # muting bob hides his notifications from both the list and the count
    assert conn
           |> post_json(alice.did, "app.bsky.graph.muteActor", %{"actor" => bob.did})
           |> response(200)

    assert conn
           |> as_viewer(alice.did, "app.bsky.notification.listNotifications")
           |> get("/xrpc/app.bsky.notification.listNotifications")
           |> valid_json!("app.bsky.notification.listNotifications")
           |> Map.get("notifications") == []

    assert conn
           |> as_viewer(alice.did, "app.bsky.notification.getUnreadCount")
           |> get("/xrpc/app.bsky.notification.getUnreadCount")
           |> valid_json!("app.bsky.notification.getUnreadCount") == %{"count" => 0}

    # bob has none
    assert conn
           |> as_viewer(bob.did, "app.bsky.notification.listNotifications")
           |> get("/xrpc/app.bsky.notification.listNotifications")
           |> valid_json!("app.bsky.notification.listNotifications")
           |> Map.get("notifications") == []

    # the seenAt query parameter is unsupported, as upstream
    assert conn
           |> as_viewer(alice.did, "app.bsky.notification.listNotifications")
           |> get("/xrpc/app.bsky.notification.listNotifications", seenAt: now())
           |> json_response(400)
  end

  test "getServices returns labeler views for indexed labeler declarations", ctx do
    %{conn: conn, alice: alice, bob: bob} = ctx

    svc =
      create(
        alice.did,
        "app.bsky.labeler.service",
        %{
          "policies" => %{"labelValues" => ["spam", "!hide"]},
          "createdAt" => now()
        },
        rkey: "self"
      )

    write!(alice.did, [svc])

    body =
      conn
      |> get("/xrpc/app.bsky.labeler.getServices", %{"dids" => [alice.did, bob.did]})
      |> valid_json!("app.bsky.labeler.getServices")

    assert [view] = body["views"]
    assert view["$type"] == "app.bsky.labeler.defs#labelerView"
    assert view["uri"] == svc.uri
    assert view["creator"]["did"] == alice.did
    assert view["creator"]["associated"]["labeler"] == true
    assert view["likeCount"] == 0
    refute Map.has_key?(view, "policies")

    body =
      conn
      |> as_viewer(bob.did, "app.bsky.labeler.getServices")
      |> get("/xrpc/app.bsky.labeler.getServices", %{"dids" => [alice.did], "detailed" => true})
      |> valid_json!("app.bsky.labeler.getServices")

    assert [view] = body["views"]
    assert view["$type"] == "app.bsky.labeler.defs#labelerViewDetailed"
    assert view["policies"] == %{"labelValues" => ["spam", "!hide"]}
    assert view["viewer"] == %{}

    assert conn
           |> get("/xrpc/app.bsky.labeler.getServices", %{"dids" => [bob.did]})
           |> valid_json!("app.bsky.labeler.getServices") == %{"views" => []}
  end
end
