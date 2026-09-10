defmodule AeroxWeb.AppView.ActorControllerTest do
  @moduledoc "app.bsky.actor.* on the AppView host (DESIGN §15.3, §15.8), against records indexed from our PDS."
  use AeroxWeb.ConnCase, async: false
  import Aerox.AppViewHelpers
  alias Aerox.PDS.Sequencer, as: PdsSeq

  setup %{conn: conn} do
    Aerox.RateLimit.reset()
    since = PdsSeq.current() || 0
    alice = signup("alice-ac")
    bob = signup("bob-ac")
    ingest_since(since)
    {:ok, conn: %{conn | host: Aerox.AppView.Config.hostname()}, alice: alice, bob: bob}
  end

  defp as_viewer(conn, did, nsid),
    do: put_req_header(conn, "authorization", "Bearer " <> service_jwt(did, nsid))

  test "getProfile by DID and by handle: detailed view with counts and viewer state", ctx do
    %{conn: conn, alice: alice, bob: bob} = ctx

    profile =
      create(
        alice.did,
        "app.bsky.actor.profile",
        %{"displayName" => "Alice", "description" => "hi"},
        rkey: "self"
      )

    write!(alice.did, [profile])
    post = create(alice.did, "app.bsky.feed.post", %{"text" => "hello", "createdAt" => now()})
    write!(alice.did, [post])

    follow =
      create(bob.did, "app.bsky.graph.follow", %{"subject" => alice.did, "createdAt" => now()})

    write!(bob.did, [follow])

    body =
      conn
      |> get("/xrpc/app.bsky.actor.getProfile", actor: alice.did)
      |> valid_json!("app.bsky.actor.getProfile")

    assert body["did"] == alice.did
    assert body["handle"] == "alice-ac.aerox.sola.town"
    assert body["displayName"] == "Alice"
    assert body["description"] == "hi"
    assert body["followersCount"] == 1
    assert body["followsCount"] == 0
    assert body["postsCount"] == 1
    refute Map.has_key?(body, "avatar")
    refute Map.has_key?(body, "viewer")

    # by handle
    assert conn
           |> get("/xrpc/app.bsky.actor.getProfile", actor: "alice-ac.aerox.sola.town")
           |> valid_json!("app.bsky.actor.getProfile")
           |> Map.get("did") == alice.did

    # bob's view: he follows alice
    body =
      conn
      |> as_viewer(bob.did, "app.bsky.actor.getProfile")
      |> get("/xrpc/app.bsky.actor.getProfile", actor: alice.did)
      |> valid_json!("app.bsky.actor.getProfile")

    assert body["viewer"]["following"] == follow.uri
    assert body["viewer"]["muted"] == false
    refute body["viewer"]["blockedBy"]

    # alice's own view of bob: followedBy
    body =
      conn
      |> as_viewer(alice.did, "app.bsky.actor.getProfile")
      |> get("/xrpc/app.bsky.actor.getProfile", actor: bob.did)
      |> valid_json!("app.bsky.actor.getProfile")

    assert body["viewer"]["followedBy"] == follow.uri

    # unknown handle and unindexed DID
    assert conn
           |> get("/xrpc/app.bsky.actor.getProfile", actor: "nobody.example.com")
           |> json_response(400) == %{
             "error" => "InvalidRequest",
             "message" => "Profile not found"
           }

    assert conn
           |> get("/xrpc/app.bsky.actor.getProfile", actor: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa")
           |> json_response(400)
           |> Map.get("message") == "Profile not found"

    # missing param
    assert conn |> get("/xrpc/app.bsky.actor.getProfile") |> json_response(400)
  end

  test "getProfile with an avatar blob emits the image CDN URL (DESIGN §16)", ctx do
    %{conn: conn, alice: alice} = ctx
    png = <<0x89, "PNG\r\n", 0x1A, "\n">> <> :crypto.strong_rand_bytes(64)
    {:ok, meta} = Aerox.PDS.Blobs.upload(alice.did, "image/png", [png])
    {:ok, ref} = Aerox.PDS.Blobs.track(alice.did, meta)
    blob = Aerox.ATProto.Data.to_json(ref)

    profile =
      create(alice.did, "app.bsky.actor.profile", %{"displayName" => "A", "avatar" => blob},
        rkey: "self"
      )

    write!(alice.did, [profile])
    cid = blob["ref"]["$link"]

    body =
      conn
      |> get("/xrpc/app.bsky.actor.getProfile", actor: alice.did)
      |> valid_json!("app.bsky.actor.getProfile")

    # DESIGN §16 shape (upstream appends `@jpeg`; our image plug takes the format from `Accept`)
    assert body["avatar"] ==
             "https://appview.aerox.sola.town/img/avatar/plain/#{alice.did}/#{cid}"
  end

  test "getProfiles returns detailed views for every known actor, in order", ctx do
    %{conn: conn, alice: alice, bob: bob} = ctx

    body =
      conn
      |> get("/xrpc/app.bsky.actor.getProfiles", %{
        "actors" => [bob.did, "alice-ac.aerox.sola.town", "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"]
      })
      |> valid_json!("app.bsky.actor.getProfiles")

    assert Enum.map(body["profiles"], & &1["did"]) == [bob.did, alice.did]
    assert Enum.all?(body["profiles"], &Map.has_key?(&1, "followersCount"))
  end

  test "getProfiles reads an array parameter sent as a repeated key", ctx do
    %{conn: conn, alice: alice, bob: bob} = ctx

    # This is the form `@atproto/api` puts on the wire — `actors=…&actors=…`,
    # not `actors[]=`. Plug keeps only the last value of a repeated key, so
    # reading conn.query_params alone answers with one profile and no error.
    body =
      conn
      |> get("/xrpc/app.bsky.actor.getProfiles?actors=#{bob.did}&actors=#{alice.did}")
      |> valid_json!("app.bsky.actor.getProfiles")

    assert Enum.map(body["profiles"], & &1["did"]) == [bob.did, alice.did]
  end

  test "getSuggestions is empty by design (DESIGN §15.4)", %{conn: conn} do
    assert conn
           |> get("/xrpc/app.bsky.actor.getSuggestions")
           |> valid_json!("app.bsky.actor.getSuggestions") == %{"actors" => []}
  end

  test "searchActorsTypeahead matches handle and display name prefixes; searchActors substrings",
       ctx do
    %{conn: conn, alice: alice, bob: bob} = ctx

    profile =
      create(bob.did, "app.bsky.actor.profile", %{"displayName" => "Robert Zed"}, rkey: "self")

    write!(bob.did, [profile])

    body =
      conn
      |> get("/xrpc/app.bsky.actor.searchActorsTypeahead", q: "alice-a")
      |> valid_json!("app.bsky.actor.searchActorsTypeahead")

    assert Enum.map(body["actors"], & &1["did"]) == [alice.did]
    # basic views carry no description
    refute Map.has_key?(hd(body["actors"]), "description")

    # display name prefix, case-insensitive; legacy `term` param
    body =
      conn
      |> get("/xrpc/app.bsky.actor.searchActorsTypeahead", term: "rob")
      |> valid_json!("app.bsky.actor.searchActorsTypeahead")

    assert Enum.map(body["actors"], & &1["did"]) == [bob.did]

    # a prefix only: "zed" is inside the display name, not at its start
    assert conn
           |> get("/xrpc/app.bsky.actor.searchActorsTypeahead", q: "zed")
           |> valid_json!("app.bsky.actor.searchActorsTypeahead") == %{"actors" => []}

    assert conn
           |> get("/xrpc/app.bsky.actor.searchActorsTypeahead", q: "")
           |> valid_json!("app.bsky.actor.searchActorsTypeahead") == %{"actors" => []}

    # searchActors: substring, paged
    body =
      conn
      |> get("/xrpc/app.bsky.actor.searchActors", q: "-ac.aerox", limit: 1)
      |> valid_json!("app.bsky.actor.searchActors")

    assert [first] = body["actors"]
    assert is_binary(body["cursor"])

    body2 =
      conn
      |> get("/xrpc/app.bsky.actor.searchActors",
        q: "-ac.aerox",
        limit: 1,
        cursor: body["cursor"]
      )
      |> valid_json!("app.bsky.actor.searchActors")

    assert [second] = body2["actors"]
    assert MapSet.new([first["did"], second["did"]]) == MapSet.new([alice.did, bob.did])
    assert Map.has_key?(first, "indexedAt")

    # LIKE metacharacters are literal
    assert conn
           |> get("/xrpc/app.bsky.actor.searchActors", q: "%")
           |> valid_json!("app.bsky.actor.searchActors")
           |> Map.get("actors") == []
  end

  test "a bad service token is refused; a token for another method is refused", ctx do
    %{conn: conn, alice: alice} = ctx

    assert conn
           |> put_req_header("authorization", "Bearer nope")
           |> get("/xrpc/app.bsky.actor.getProfile", actor: alice.did)
           |> json_response(401)

    assert conn
           |> as_viewer(alice.did, "app.bsky.feed.getTimeline")
           |> get("/xrpc/app.bsky.actor.getProfile", actor: alice.did)
           |> json_response(401)
  end
end
