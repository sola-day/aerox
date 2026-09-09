defmodule AeroxWeb.AppView.GraphControllerTest do
  @moduledoc "app.bsky.graph.* on the AppView host (DESIGN §15.3, §15.7), against records indexed from our PDS."
  use AeroxWeb.ConnCase, async: false
  import Aerox.AppViewHelpers
  alias Aerox.PDS.Sequencer, as: PdsSeq

  setup %{conn: conn} do
    Aerox.RateLimit.reset()
    since = PdsSeq.current() || 0
    alice = signup("alice-gc")
    bob = signup("bob-gc")
    carol = signup("carol-gc")
    ingest_since(since)

    {:ok,
     conn: %{conn | host: Aerox.AppView.Config.hostname()}, alice: alice, bob: bob, carol: carol}
  end

  defp as_viewer(conn, did, nsid),
    do: put_req_header(conn, "authorization", "Bearer " <> service_jwt(did, nsid))

  defp follow(from, to),
    do: create(from.did, "app.bsky.graph.follow", %{"subject" => to.did, "createdAt" => now()})

  defp post_json(conn, did, nsid, body) do
    conn
    |> as_viewer(did, nsid)
    |> put_req_header("content-type", "application/json")
    |> post("/xrpc/#{nsid}", Jason.encode!(body))
  end

  test "getFollows / getFollowers page with cursors; getKnownFollowers; getRelationships", ctx do
    %{conn: conn, alice: alice, bob: bob, carol: carol} = ctx
    # alice follows bob and carol; bob and carol follow alice; bob follows carol
    write!(alice.did, [follow(alice, bob)])
    write!(alice.did, [follow(alice, carol)])
    write!(bob.did, [follow(bob, alice)])
    f_bc = follow(bob, carol)
    write!(bob.did, [f_bc])
    write!(carol.did, [follow(carol, alice)])

    page1 =
      conn
      |> get("/xrpc/app.bsky.graph.getFollows", actor: "alice-gc.aerox.sola.town", limit: 1)
      |> valid_json!("app.bsky.graph.getFollows")

    assert page1["subject"]["did"] == alice.did
    assert [%{"did" => first}] = page1["follows"]
    assert is_binary(page1["cursor"])

    page2 =
      conn
      |> get("/xrpc/app.bsky.graph.getFollows",
        actor: alice.did,
        limit: 1,
        cursor: page1["cursor"]
      )
      |> valid_json!("app.bsky.graph.getFollows")

    assert [%{"did" => second}] = page2["follows"]
    # newest follow first
    assert [first, second] == [carol.did, bob.did]

    page3 =
      conn
      |> get("/xrpc/app.bsky.graph.getFollows",
        actor: alice.did,
        limit: 1,
        cursor: page2["cursor"]
      )
      |> valid_json!("app.bsky.graph.getFollows")

    assert page3["follows"] == []
    refute Map.has_key?(page3, "cursor")

    # a cursor that cannot be ours yields an empty page rather than an error
    assert conn
           |> get("/xrpc/app.bsky.graph.getFollows", actor: alice.did, cursor: "garbage")
           |> valid_json!("app.bsky.graph.getFollows")
           |> Map.get("follows") == []

    followers =
      conn
      |> get("/xrpc/app.bsky.graph.getFollowers", actor: alice.did)
      |> valid_json!("app.bsky.graph.getFollowers")

    assert Enum.map(followers["followers"], & &1["did"]) == [carol.did, bob.did]
    refute Map.has_key?(followers, "cursor")

    assert conn
           |> get("/xrpc/app.bsky.graph.getFollows", actor: "nobody-gc.aerox.sola.town")
           |> json_response(400)
           |> Map.get("message") =~ "Actor not found"

    # known followers: viewer alice looks at carol; alice follows bob, and bob follows carol
    known =
      conn
      |> as_viewer(alice.did, "app.bsky.graph.getKnownFollowers")
      |> get("/xrpc/app.bsky.graph.getKnownFollowers", actor: carol.did)
      |> valid_json!("app.bsky.graph.getKnownFollowers")

    assert known["subject"]["did"] == carol.did
    assert Enum.map(known["followers"], & &1["did"]) == [bob.did]

    # ... and the detailed profile carries the same
    detailed =
      conn
      |> as_viewer(alice.did, "app.bsky.actor.getProfile")
      |> get("/xrpc/app.bsky.actor.getProfile", actor: carol.did)
      |> valid_json!("app.bsky.actor.getProfile")

    assert detailed["viewer"]["knownFollowers"]["count"] == 1
    bob_did = bob.did
    assert [%{"did" => ^bob_did}] = detailed["viewer"]["knownFollowers"]["followers"]

    assert conn
           |> get("/xrpc/app.bsky.graph.getKnownFollowers", actor: carol.did)
           |> json_response(401)
           |> Map.get("error") == "AuthMissing"

    # relationships
    rel =
      conn
      |> get("/xrpc/app.bsky.graph.getRelationships", %{
        "actor" => bob.did,
        "others" => [
          carol.did,
          alice.did,
          "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
          "nobody.example.com"
        ]
      })
      |> valid_json!("app.bsky.graph.getRelationships")

    assert rel["actor"] == bob.did
    [r_carol, r_alice, r_unknown_did, r_unknown_handle] = rel["relationships"]
    assert r_carol["did"] == carol.did and r_carol["following"] == f_bc.uri
    refute Map.has_key?(r_carol, "followedBy")
    assert r_alice["did"] == alice.did
    assert is_binary(r_alice["following"]) and is_binary(r_alice["followedBy"])
    # an unindexed DID still gets an (empty) relationship, as upstream's naive viewer states do
    assert r_unknown_did == %{
             "$type" => "app.bsky.graph.defs#relationship",
             "did" => "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
           }

    assert r_unknown_handle["notFound"] == true and
             r_unknown_handle["actor"] == "nobody.example.com"

    # an unknown actor: everything not found
    rel =
      conn
      |> get("/xrpc/app.bsky.graph.getRelationships", %{
        "actor" => "nobody.example.com",
        "others" => [carol.did]
      })
      |> valid_json!("app.bsky.graph.getRelationships")

    refute Map.has_key?(rel, "actor")
    assert [%{"notFound" => true}] = rel["relationships"]
  end

  test "blocks hide follow pairs from getFollows/getFollowers and appear in getBlocks", ctx do
    %{conn: conn, alice: alice, bob: bob, carol: carol} = ctx
    write!(alice.did, [follow(alice, bob), follow(alice, carol)])

    block =
      create(carol.did, "app.bsky.graph.block", %{"subject" => alice.did, "createdAt" => now()})

    write!(carol.did, [block])

    follows =
      conn
      |> get("/xrpc/app.bsky.graph.getFollows", actor: alice.did)
      |> valid_json!("app.bsky.graph.getFollows")

    assert Enum.map(follows["follows"], & &1["did"]) == [bob.did]

    # the viewer's own blocks also hide people
    write!(bob.did, [
      create(bob.did, "app.bsky.graph.follow", %{"subject" => carol.did, "createdAt" => now()})
    ])

    assert conn
           |> as_viewer(alice.did, "app.bsky.graph.getFollows")
           |> get("/xrpc/app.bsky.graph.getFollows", actor: bob.did)
           |> valid_json!("app.bsky.graph.getFollows")
           |> Map.get("follows") == []

    blocks =
      conn
      |> as_viewer(carol.did, "app.bsky.graph.getBlocks")
      |> get("/xrpc/app.bsky.graph.getBlocks")
      |> valid_json!("app.bsky.graph.getBlocks")

    assert [%{"did" => did, "viewer" => viewer}] = blocks["blocks"]
    assert did == alice.did and viewer["blocking"] == block.uri

    assert conn |> get("/xrpc/app.bsky.graph.getBlocks") |> json_response(401)
  end

  test "muteActor/unmuteActor flip viewer.muted and getMutes; muting yourself is refused", ctx do
    %{conn: conn, alice: alice, bob: bob} = ctx

    assert conn
           |> post_json(alice.did, "app.bsky.graph.muteActor", %{
             "actor" => "bob-gc.aerox.sola.town"
           })
           |> response(200)

    profile =
      conn
      |> as_viewer(alice.did, "app.bsky.actor.getProfile")
      |> get("/xrpc/app.bsky.actor.getProfile", actor: bob.did)
      |> valid_json!("app.bsky.actor.getProfile")

    assert profile["viewer"]["muted"] == true

    mutes =
      conn
      |> as_viewer(alice.did, "app.bsky.graph.getMutes")
      |> get("/xrpc/app.bsky.graph.getMutes")
      |> valid_json!("app.bsky.graph.getMutes")

    assert Enum.map(mutes["mutes"], & &1["did"]) == [bob.did]
    refute Map.has_key?(mutes, "cursor")

    # idempotent
    assert conn
           |> post_json(alice.did, "app.bsky.graph.muteActor", %{"actor" => bob.did})
           |> response(200)

    # bob does not see himself as muted, and sees no mutes of his own
    refute conn
           |> as_viewer(bob.did, "app.bsky.actor.getProfile")
           |> get("/xrpc/app.bsky.actor.getProfile", actor: bob.did)
           |> valid_json!("app.bsky.actor.getProfile")
           |> get_in(["viewer", "muted"])

    assert conn
           |> post_json(alice.did, "app.bsky.graph.unmuteActor", %{"actor" => bob.did})
           |> response(200)

    refute conn
           |> as_viewer(alice.did, "app.bsky.actor.getProfile")
           |> get("/xrpc/app.bsky.actor.getProfile", actor: bob.did)
           |> valid_json!("app.bsky.actor.getProfile")
           |> get_in(["viewer", "muted"])

    assert conn
           |> post_json(alice.did, "app.bsky.graph.muteActor", %{"actor" => alice.did})
           |> json_response(400)
           |> Map.get("message") == "Actor cannot mute themselves"

    assert conn
           |> post_json(alice.did, "app.bsky.graph.muteActor", %{"actor" => "nobody.example.com"})
           |> json_response(400)
           |> Map.get("message") == "Actor not found"

    assert conn
           |> put_req_header("content-type", "application/json")
           |> post("/xrpc/app.bsky.graph.muteActor", Jason.encode!(%{"actor" => bob.did}))
           |> json_response(401)

    # thread mutes
    root = create(bob.did, "app.bsky.feed.post", %{"text" => "root", "createdAt" => now()})
    write!(bob.did, [root])

    assert conn
           |> post_json(alice.did, "app.bsky.graph.muteThread", %{"root" => root.uri})
           |> response(200)

    assert Aerox.AppView.Repo.get_by(Aerox.AppView.Schema.ThreadMute,
             muted_by_did: alice.did,
             root_uri: root.uri
           )

    assert conn
           |> post_json(alice.did, "app.bsky.graph.unmuteThread", %{"root" => root.uri})
           |> response(200)

    refute Aerox.AppView.Repo.get_by(Aerox.AppView.Schema.ThreadMute,
             muted_by_did: alice.did,
             root_uri: root.uri
           )
  end

  test "getList, getLists, list mutes and list blocks", ctx do
    %{conn: conn, alice: alice, bob: bob, carol: carol} = ctx

    list =
      create(alice.did, "app.bsky.graph.list", %{
        "name" => "Friends",
        "purpose" => "app.bsky.graph.defs#curatelist",
        "description" => "the good ones",
        "createdAt" => now()
      })

    write!(alice.did, [list])

    item_b =
      create(alice.did, "app.bsky.graph.listitem", %{
        "subject" => bob.did,
        "list" => list.uri,
        "createdAt" => now()
      })

    write!(alice.did, [item_b])

    item_c =
      create(alice.did, "app.bsky.graph.listitem", %{
        "subject" => carol.did,
        "list" => list.uri,
        "createdAt" => now()
      })

    write!(alice.did, [item_c])

    body =
      conn
      |> get("/xrpc/app.bsky.graph.getList", list: list.uri, limit: 1)
      |> valid_json!("app.bsky.graph.getList")

    assert body["list"]["uri"] == list.uri
    assert body["list"]["name"] == "Friends"
    assert body["list"]["creator"]["did"] == alice.did
    assert body["list"]["listItemCount"] == 2
    assert [%{"uri" => uri, "subject" => %{"did" => did}}] = body["items"]
    assert {uri, did} == {item_c.uri, carol.did}

    body2 =
      conn
      |> get("/xrpc/app.bsky.graph.getList", list: list.uri, limit: 1, cursor: body["cursor"])
      |> valid_json!("app.bsky.graph.getList")

    assert [%{"uri" => uri2}] = body2["items"]
    assert uri2 == item_b.uri

    assert conn
           |> get("/xrpc/app.bsky.graph.getList",
             list: "at://#{alice.did}/app.bsky.graph.list/nope"
           )
           |> json_response(400)
           |> Map.get("message") == "List not found"

    lists =
      conn
      |> get("/xrpc/app.bsky.graph.getLists", actor: alice.did)
      |> valid_json!("app.bsky.graph.getLists")

    list_uri = list.uri
    assert [%{"uri" => ^list_uri, "description" => "the good ones"}] = lists["lists"]

    assert conn
           |> get("/xrpc/app.bsky.graph.getLists", actor: bob.did)
           |> valid_json!("app.bsky.graph.getLists") == %{"lists" => []}

    # bob mutes the list: carol (a member) shows as muted by list for him
    assert conn
           |> post_json(bob.did, "app.bsky.graph.muteActorList", %{"list" => list.uri})
           |> response(200)

    muted =
      conn
      |> as_viewer(bob.did, "app.bsky.graph.getListMutes")
      |> get("/xrpc/app.bsky.graph.getListMutes")
      |> valid_json!("app.bsky.graph.getListMutes")

    assert [%{"uri" => ^list_uri, "viewer" => %{"muted" => true}}] = muted["lists"]

    profile =
      conn
      |> as_viewer(bob.did, "app.bsky.actor.getProfile")
      |> get("/xrpc/app.bsky.actor.getProfile", actor: carol.did)
      |> valid_json!("app.bsky.actor.getProfile")

    assert profile["viewer"]["muted"] == true
    assert profile["viewer"]["mutedByList"]["uri"] == list.uri

    assert conn
           |> post_json(bob.did, "app.bsky.graph.unmuteActorList", %{"list" => list.uri})
           |> response(200)

    assert conn
           |> as_viewer(bob.did, "app.bsky.graph.getListMutes")
           |> get("/xrpc/app.bsky.graph.getListMutes")
           |> valid_json!("app.bsky.graph.getListMutes") == %{"lists" => []}

    # a listblock record indexed from the firehose shows in getListBlocks
    lb =
      create(bob.did, "app.bsky.graph.listblock", %{"subject" => list.uri, "createdAt" => now()})

    write!(bob.did, [lb])

    blocked =
      conn
      |> as_viewer(bob.did, "app.bsky.graph.getListBlocks")
      |> get("/xrpc/app.bsky.graph.getListBlocks")
      |> valid_json!("app.bsky.graph.getListBlocks")

    assert [%{"uri" => ^list_uri, "viewer" => %{"blocked" => blocked_uri}}] = blocked["lists"]
    assert blocked_uri == lb.uri
  end

  test "starter packs: getStarterPack, getStarterPacks, getActorStarterPacks", ctx do
    %{conn: conn, alice: alice, bob: bob} = ctx

    list =
      create(alice.did, "app.bsky.graph.list", %{
        "name" => "Pack list",
        "purpose" => "app.bsky.graph.defs#referencelist",
        "createdAt" => now()
      })

    write!(alice.did, [list])

    item =
      create(alice.did, "app.bsky.graph.listitem", %{
        "subject" => bob.did,
        "list" => list.uri,
        "createdAt" => now()
      })

    write!(alice.did, [item])

    pack =
      create(alice.did, "app.bsky.graph.starterpack", %{
        "name" => "Starter",
        "list" => list.uri,
        "createdAt" => now()
      })

    write!(alice.did, [pack])

    body =
      conn
      |> get("/xrpc/app.bsky.graph.getStarterPack", starterPack: pack.uri)
      |> valid_json!("app.bsky.graph.getStarterPack")

    sp = body["starterPack"]
    assert sp["uri"] == pack.uri
    assert sp["record"]["name"] == "Starter"
    assert sp["creator"]["did"] == alice.did
    assert sp["list"]["uri"] == list.uri
    assert [%{"subject" => %{"did" => member}}] = sp["listItemsSample"]
    assert member == bob.did
    assert sp["joinedAllTimeCount"] == 0

    # by handle in the URI, as upstream resolveUri allows
    handle_uri = "at://alice-gc.aerox.sola.town/app.bsky.graph.starterpack/#{pack.rkey}"

    assert conn
           |> get("/xrpc/app.bsky.graph.getStarterPack", starterPack: handle_uri)
           |> valid_json!("app.bsky.graph.getStarterPack")
           |> get_in(["starterPack", "uri"]) == pack.uri

    assert conn
           |> get("/xrpc/app.bsky.graph.getStarterPack",
             starterPack: "at://#{alice.did}/app.bsky.graph.starterpack/nope"
           )
           |> json_response(400)
           |> Map.get("message") == "Starter pack not found"

    assert conn
           |> get("/xrpc/app.bsky.graph.getStarterPacks", %{
             "uris" => [pack.uri, "at://#{alice.did}/app.bsky.graph.starterpack/nope"]
           })
           |> valid_json!("app.bsky.graph.getStarterPacks")
           |> Map.get("starterPacks")
           |> Enum.map(& &1["uri"]) == [pack.uri]

    body =
      conn
      |> get("/xrpc/app.bsky.graph.getActorStarterPacks", actor: alice.did)
      |> valid_json!("app.bsky.graph.getActorStarterPacks")

    assert Enum.map(body["starterPacks"], & &1["uri"]) == [pack.uri]
    refute Map.has_key?(hd(body["starterPacks"]), "list")

    # the profile's associated counts see the pack
    assert conn
           |> get("/xrpc/app.bsky.actor.getProfile", actor: alice.did)
           |> valid_json!("app.bsky.actor.getProfile")
           |> get_in(["associated", "starterPacks"]) == 1
  end
end
