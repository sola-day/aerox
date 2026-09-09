defmodule AeroxWeb.AppView.FeedControllerTest do
  @moduledoc """
  VERIFICATION §5 AppView feeds: `app.bsky.feed.*` served by the AppView
  host against real accounts on our PDS, records written through the PDS
  write path and indexed from the firehose. Every 200 body validates against
  the vendored lexicon.
  """
  use AeroxWeb.ConnCase, async: false
  alias Aerox.ATProto.Lexicon
  alias Aerox.AppView.Config
  alias Aerox.PDS.Records
  alias Aerox.PDS.Records.Prepare
  alias Aerox.PDS.Sequencer, as: PdsSeq
  alias Aerox.AppView.Ingest.Indexer

  defmodule StubFeedGen do
    @moduledoc "A feed generator: answers getFeedSkeleton with the posts in `:aerox, :test_feedgen`."
    @behaviour Plug
    import Plug.Conn

    def init(opts), do: opts

    def call(%{request_path: "/xrpc/app.bsky.feed.getFeedSkeleton"} = conn, _) do
      conn = fetch_query_params(conn)
      %{pid: pid, posts: posts} = Application.get_env(:aerox, :test_feedgen)

      claims =
        case get_req_header(conn, "authorization") do
          ["Bearer " <> jwt] ->
            jwt
            |> String.split(".")
            |> Enum.at(1)
            |> Base.url_decode64!(padding: false)
            |> Jason.decode!()

          _ ->
            nil
        end

      send(pid, {:feedgen_called, claims, conn.query_params})

      feed =
        Enum.map(posts, fn
          {:repost, post, repost} ->
            %{
              "post" => post,
              "reason" => %{
                "$type" => "app.bsky.feed.defs#skeletonReasonRepost",
                "repost" => repost
              }
            }

          post ->
            %{"post" => post, "feedContext" => "ctx"}
        end)

      body = %{"feed" => feed, "cursor" => "next-page", "reqId" => "req-1"}

      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("content-language", "en")
      |> send_resp(200, Jason.encode!(body))
    end

    def call(conn, _), do: send_resp(conn, 404, "not found")
  end

  setup %{conn: conn} do
    Aerox.RateLimit.reset()
    since = PdsSeq.current() || 0
    {:ok, alice} = signup("alice-fc")
    {:ok, bob} = signup("bob-fc")
    {:ok, carol} = signup("carol-fc")
    ingest_since(since)
    {:ok, conn: %{conn | host: Config.hostname()}, alice: alice, bob: bob, carol: carol}
  end

  # ------------------------------------------------------------ helpers

  defp signup(name) do
    Aerox.PDS.Signup.create(%{
      handle: "#{name}.aerox.sola.town",
      email: "#{name}@example.com",
      password: "pw-pw-pw-pw"
    })
  end

  defp write!(did, writes) do
    before = PdsSeq.current() || 0
    {:ok, commit} = Records.process_writes(did, writes)
    ingest_since(before)
    commit
  end

  defp ingest_since(seq) do
    for row <- PdsSeq.range(seq, 1000) do
      {type, body} = PdsSeq.Events.to_frame(row)
      assert :ok = Indexer.process(type, body), "#{type} seq=#{row.seq}"
    end
  end

  defp create(did, collection, record, opts \\ []) do
    {:ok, w} = Prepare.create(did, collection, Map.put(record, "$type", collection), opts)
    w
  end

  # createdAt strictly increasing per call so sort_at (min of created/indexed) orders as written
  defp at(offset_s),
    do: DateTime.utc_now() |> DateTime.add(offset_s - 1000, :second) |> DateTime.to_iso8601()

  defp make_post(did, text, offset, extra \\ %{}) do
    create(
      did,
      "app.bsky.feed.post",
      Map.merge(%{"text" => text, "createdAt" => at(offset)}, extra)
    )
  end

  defp ref(w), do: %{"uri" => w.uri, "cid" => to_string(w.cid)}

  defp reply(did, text, offset, root, parent),
    do:
      make_post(did, text, offset, %{"reply" => %{"root" => ref(root), "parent" => ref(parent)}})

  defp like(did, subject, offset),
    do: create(did, "app.bsky.feed.like", %{"subject" => ref(subject), "createdAt" => at(offset)})

  defp repost(did, subject, offset),
    do:
      create(did, "app.bsky.feed.repost", %{"subject" => ref(subject), "createdAt" => at(offset)})

  defp follow(did, subject, offset),
    do: create(did, "app.bsky.graph.follow", %{"subject" => subject, "createdAt" => at(offset)})

  defp block(did, subject, offset),
    do: create(did, "app.bsky.graph.block", %{"subject" => subject, "createdAt" => at(offset)})

  defp auth(conn, did, nsid) do
    jwt =
      Aerox.Auth.ServiceJWT.create(
        keypair: Aerox.PDS.Accounts.signing_keypair(did),
        iss: did,
        aud: Config.service_did(),
        lxm: nsid
      )

    put_req_header(conn, "authorization", "Bearer " <> jwt)
  end

  # GET an XRPC method, assert 200, validate the body against the lexicon
  defp xrpc!(conn, nsid, query, viewer \\ nil) do
    conn = if viewer, do: auth(conn, viewer, nsid), else: conn
    resp = get(conn, "/xrpc/#{nsid}?#{URI.encode_query(query)}")
    body = json_response(resp, 200)

    assert {:ok, _} = Lexicon.validate_output(Lexicon.default_registry(), nsid, body),
           "#{nsid} output does not validate: #{inspect(body)}"

    assert [_] = get_resp_header(resp, "atproto-content-labelers")
    body
  end

  defp xrpc_error(conn, nsid, query, viewer \\ nil) do
    conn = if viewer, do: auth(conn, viewer, nsid), else: conn
    resp = get(conn, "/xrpc/#{nsid}?#{URI.encode_query(query)}")
    {resp.status, Jason.decode!(resp.resp_body)}
  end

  defp feed_uris(body),
    do: Enum.map(body["feed"], &{&1["post"]["uri"], get_in(&1, ["reason", "uri"])})

  # -------------------------------------------------------------- timeline

  test "getTimeline: own posts, followed posts and reposts, reply rules, cursor paging", ctx do
    %{conn: conn, alice: alice, bob: bob, carol: carol} = ctx
    write!(bob.did, [follow(bob.did, alice.did, 0)])

    c1 = make_post(carol.did, "carol 1", 1)
    write!(carol.did, [c1])
    b1 = make_post(bob.did, "bob 1", 2)
    write!(bob.did, [b1])
    a1 = make_post(alice.did, "alice 1", 3)
    a_repost = repost(alice.did, c1, 4)
    # reply to a non-followed account (carol): hidden from bob's timeline
    a_reply_carol = reply(alice.did, "alice → carol", 5, c1, c1)
    # reply to the viewer: shown
    a_reply_bob = reply(alice.did, "alice → bob", 6, b1, b1)
    a2 = make_post(alice.did, "alice 2", 7)
    # alice's self-thread reply: shown
    a_self = reply(alice.did, "alice → alice", 8, a2, a2)
    write!(alice.did, [a1, a_repost, a_reply_carol, a_reply_bob, a2, a_self])
    # carol is not followed: her repost of alice is not in the timeline
    write!(carol.did, [repost(carol.did, a1, 9)])

    assert {401, %{"error" => "AuthenticationRequired"}} =
             xrpc_error(conn, "app.bsky.feed.getTimeline", %{})

    body = xrpc!(conn, "app.bsky.feed.getTimeline", %{}, bob.did)

    assert feed_uris(body) == [
             {a_self.uri, nil},
             {a2.uri, nil},
             {a_reply_bob.uri, nil},
             {c1.uri, a_repost.uri},
             {a1.uri, nil},
             {b1.uri, nil}
           ]

    refute body["cursor"]
    [self_item | _] = body["feed"]
    assert self_item["reply"]["parent"]["uri"] == a2.uri

    assert self_item["post"]["viewer"] == %{
             "threadMuted" => false,
             "embeddingDisabled" => false,
             "bookmarked" => false
           }

    repost_item = Enum.at(body["feed"], 3)
    assert repost_item["reason"]["$type"] == "app.bsky.feed.defs#reasonRepost"
    assert repost_item["reason"]["by"]["did"] == alice.did

    # paging by 2 walks the same list without gaps or duplicates
    pages =
      Stream.unfold({:start, nil}, fn
        :done ->
          nil

        {_, cursor} ->
          q = if cursor, do: %{"limit" => 2, "cursor" => cursor}, else: %{"limit" => 2}
          page = xrpc!(conn, "app.bsky.feed.getTimeline", q, bob.did)
          next = if page["cursor"], do: {:page, page["cursor"]}, else: :done
          {feed_uris(page), next}
      end)
      |> Enum.to_list()

    assert List.flatten(pages) |> Enum.chunk_every(1) |> List.flatten() == feed_uris(body)
    assert length(pages) == 4 and List.last(pages) == []
  end

  # ------------------------------------------------------------ author feed

  test "getAuthorFeed: the five filters, pins, handles and block errors", ctx do
    %{conn: conn, alice: alice, bob: bob, carol: carol} = ctx
    b1 = make_post(bob.did, "bob root", 1)
    write!(bob.did, [b1])

    root = make_post(alice.did, "root", 2)
    to_bob = reply(alice.did, "→ bob", 3, b1, b1)
    self_reply = reply(alice.did, "self thread", 4, root, root)

    png = <<137, "PNG", 13, 10, 26, 10>> <> :crypto.strong_rand_bytes(64)
    {:ok, meta} = Aerox.PDS.Blobs.upload(alice.did, "image/png", [png])
    {:ok, _} = Aerox.PDS.Blobs.track(alice.did, meta)

    with_image =
      make_post(alice.did, "pic", 5, %{
        "embed" => %{
          "$type" => "app.bsky.embed.images",
          "images" => [
            %{
              "alt" => "a",
              "image" => %{
                "$type" => "blob",
                "ref" => %{"$link" => to_string(meta.cid)},
                "mimeType" => meta.mime_type,
                "size" => meta.size
              }
            }
          ]
        }
      })

    rp = repost(alice.did, b1, 6)

    profile =
      create(
        alice.did,
        "app.bsky.actor.profile",
        %{"displayName" => "Alice", "pinnedPost" => ref(root)},
        rkey: "self"
      )

    write!(alice.did, [root, to_bob, self_reply, with_image, rp, profile])

    feed = fn filter, extra ->
      conn
      |> xrpc!(
        "app.bsky.feed.getAuthorFeed",
        Map.merge(%{"actor" => alice.handle, "filter" => filter}, extra)
      )
      |> feed_uris()
    end

    all = [
      {b1.uri, rp.uri},
      {with_image.uri, nil},
      {self_reply.uri, nil},
      {to_bob.uri, nil},
      {root.uri, nil}
    ]

    assert feed.("posts_with_replies", %{}) == all

    assert feed.("posts_no_replies", %{}) == [
             {b1.uri, rp.uri},
             {with_image.uri, nil},
             {root.uri, nil}
           ]

    assert feed.("posts_with_media", %{}) == [{with_image.uri, nil}]
    assert feed.("posts_with_video", %{}) == []

    assert feed.("posts_and_author_threads", %{}) ==
             [{b1.uri, rp.uri}, {with_image.uri, nil}, {self_reply.uri, nil}, {root.uri, nil}]

    # includePins: the pinned post first, once, only on the first page
    pinned =
      xrpc!(conn, "app.bsky.feed.getAuthorFeed", %{"actor" => alice.did, "includePins" => true})

    assert feed_uris(pinned) == [{root.uri, nil} | List.delete(all, {root.uri, nil})]
    assert hd(pinned["feed"])["reason"] == %{"$type" => "app.bsky.feed.defs#reasonPin"}

    page2 = xrpc!(conn, "app.bsky.feed.getAuthorFeed", %{"actor" => alice.did, "limit" => 2})
    assert page2["cursor"]

    assert conn
           |> xrpc!("app.bsky.feed.getAuthorFeed", %{
             "actor" => alice.did,
             "limit" => 2,
             "cursor" => page2["cursor"]
           })
           |> feed_uris() == Enum.slice(all, 2, 2)

    # the image embed renders through the image CDN
    [%{"post" => %{"embed" => embed}}] =
      xrpc!(conn, "app.bsky.feed.getAuthorFeed", %{
        "actor" => alice.did,
        "filter" => "posts_with_media"
      })["feed"]

    assert embed["$type"] == "app.bsky.embed.images#view"
    assert [%{"thumb" => "https://" <> _}] = embed["images"]

    assert {400, %{"error" => "InvalidRequest", "message" => "Profile not found"}} =
             xrpc_error(conn, "app.bsky.feed.getAuthorFeed", %{
               "actor" => "nobody.aerox.sola.town"
             })

    # blocks in either direction are errors for the viewer
    write!(carol.did, [block(carol.did, alice.did, 7)])

    assert {400, %{"error" => "BlockedActor"}} =
             xrpc_error(conn, "app.bsky.feed.getAuthorFeed", %{"actor" => alice.did}, carol.did)

    assert {400, %{"error" => "BlockedByActor"}} =
             xrpc_error(conn, "app.bsky.feed.getAuthorFeed", %{"actor" => carol.did}, alice.did)
  end

  # ----------------------------------------------------------------- thread

  test "getPostThread: parents, replies, blocked and not-found placeholders, thread gates", ctx do
    %{conn: conn, alice: alice, bob: bob, carol: carol} = ctx
    root = make_post(alice.did, "root", 1)
    write!(alice.did, [root])
    r1 = reply(bob.did, "r1", 2, root, root)
    write!(bob.did, [r1])
    r2 = reply(carol.did, "r2", 3, root, r1)
    r2b = reply(carol.did, "r2b", 4, root, root)
    write!(carol.did, [r2, r2b])
    r3 = reply(alice.did, "r3", 5, root, r2)
    write!(alice.did, [r3])

    body = xrpc!(conn, "app.bsky.feed.getPostThread", %{"uri" => r1.uri})
    thread = body["thread"]
    assert thread["$type"] == "app.bsky.feed.defs#threadViewPost"
    assert thread["post"]["uri"] == r1.uri
    assert thread["parent"]["post"]["uri"] == root.uri
    refute thread["parent"]["parent"]

    assert [%{"post" => %{"uri" => r2_uri}, "replies" => [%{"post" => %{"uri" => r3_uri}}]}] =
             thread["replies"]

    assert {r2_uri, r3_uri} == {r2.uri, r3.uri}
    assert thread["post"]["replyCount"] == 1

    # depth / parentHeight limits
    body =
      xrpc!(conn, "app.bsky.feed.getPostThread", %{
        "uri" => r1.uri,
        "depth" => 1,
        "parentHeight" => 0
      })

    refute body["thread"]["parent"]
    assert [%{"post" => %{"uri" => ^r2_uri}} = only] = body["thread"]["replies"]
    refute only["replies"]

    # the whole tree from the root
    body = xrpc!(conn, "app.bsky.feed.getPostThread", %{"uri" => root.uri})

    assert body["thread"]["replies"] |> Enum.map(& &1["post"]["uri"]) |> Enum.sort() ==
             Enum.sort([r1.uri, r2b.uri])

    # alice blocks carol: carol's reply under alice's own post is a 3p block and is
    # omitted (upstream postBlocks.parent); her reply under bob's is #blockedPost for alice
    write!(alice.did, [block(alice.did, carol.did, 6)])
    body = xrpc!(conn, "app.bsky.feed.getPostThread", %{"uri" => root.uri}, alice.did)
    assert [r1_view] = body["thread"]["replies"]
    assert r1_view["post"]["uri"] == r1.uri
    assert [blocked] = r1_view["replies"]
    assert blocked["$type"] == "app.bsky.feed.defs#blockedPost"
    assert blocked["uri"] == r2.uri
    assert blocked["author"]["did"] == carol.did
    assert blocked["author"]["viewer"]["blocking"]
    # for bob the 3p-blocked reply is also gone, but carol's reply to him is visible
    body = xrpc!(conn, "app.bsky.feed.getPostThread", %{"uri" => root.uri}, bob.did)
    assert [%{"replies" => [%{"post" => %{"uri" => ^r2_uri}}]}] = body["thread"]["replies"]

    # a deleted parent is #notFoundPost; a deleted anchor is NotFound
    {:ok, del} = Prepare.delete(bob.did, "app.bsky.feed.post", r1.rkey)
    write!(bob.did, [del])
    body = xrpc!(conn, "app.bsky.feed.getPostThread", %{"uri" => r2.uri})

    assert body["thread"]["parent"] == %{
             "$type" => "app.bsky.feed.defs#notFoundPost",
             "uri" => r1.uri,
             "notFound" => true
           }

    assert {400, %{"error" => "NotFound"}} =
             xrpc_error(conn, "app.bsky.feed.getPostThread", %{"uri" => r1.uri})

    # a thread-gated reply is omitted and the gate is returned
    gated = make_post(alice.did, "gated", 7)

    gate =
      create(
        alice.did,
        "app.bsky.feed.threadgate",
        %{"post" => gated.uri, "allow" => [], "createdAt" => at(7)},
        rkey: gated.rkey
      )

    write!(alice.did, [gated, gate])
    write!(bob.did, [reply(bob.did, "sneaky", 8, gated, gated)])
    body = xrpc!(conn, "app.bsky.feed.getPostThread", %{"uri" => gated.uri}, bob.did)
    assert body["thread"]["replies"] == []
    assert body["threadgate"]["uri"] == gate.uri
    assert body["thread"]["post"]["viewer"]["replyDisabled"] == true
  end

  # -------------------------------------------------------- posts & subjects

  test "getPosts, getLikes, getRepostedBy, getQuotes, getActorLikes", ctx do
    %{conn: conn, alice: alice, bob: bob, carol: carol} = ctx
    p1 = make_post(alice.did, "one", 1)
    p2 = make_post(alice.did, "two", 2)
    write!(alice.did, [p1, p2])

    bl = like(bob.did, p1, 3)
    br = repost(bob.did, p1, 4)

    bq =
      make_post(bob.did, "quoting", 5, %{
        "embed" => %{"$type" => "app.bsky.embed.record", "record" => ref(p1)}
      })

    write!(bob.did, [bl, br, bq])
    cl = like(carol.did, p1, 6)
    write!(carol.did, [cl, like(carol.did, p2, 7)])

    # getPosts with repeated `uris` params, unknown uris omitted
    body =
      xrpc!(conn, "app.bsky.feed.getPosts", [
        {"uris", p2.uri},
        {"uris", p1.uri},
        {"uris", "at://#{alice.did}/app.bsky.feed.post/nope"}
      ])

    assert Enum.map(body["posts"], & &1["uri"]) == [p2.uri, p1.uri]
    [_, p1_view] = body["posts"]
    assert %{"likeCount" => 2, "repostCount" => 1, "quoteCount" => 1, "replyCount" => 0} = p1_view
    assert p1_view["author"]["handle"] == alice.handle
    assert p1_view["record"]["text"] == "one"

    body =
      xrpc!(
        conn,
        "app.bsky.feed.getLikes",
        %{"uri" => p1.uri, "cid" => to_string(p1.cid)},
        alice.did
      )

    assert body["uri"] == p1.uri and body["cid"] == to_string(p1.cid)
    assert Enum.map(body["likes"], & &1["actor"]["did"]) == [carol.did, bob.did]
    assert Enum.all?(body["likes"], &(&1["createdAt"] && &1["indexedAt"]))

    page = xrpc!(conn, "app.bsky.feed.getLikes", %{"uri" => p1.uri, "limit" => 1})
    assert [%{"actor" => %{"did" => carol_did}}] = page["likes"]
    assert carol_did == carol.did

    assert [%{"actor" => %{"did" => bob_did}}] =
             xrpc!(conn, "app.bsky.feed.getLikes", %{
               "uri" => p1.uri,
               "limit" => 1,
               "cursor" => page["cursor"]
             })["likes"]

    assert bob_did == bob.did

    body = xrpc!(conn, "app.bsky.feed.getRepostedBy", %{"uri" => p1.uri})
    assert [%{"did" => ^bob_did, "handle" => _}] = body["repostedBy"]

    body = xrpc!(conn, "app.bsky.feed.getQuotes", %{"uri" => p1.uri}, alice.did)
    assert [%{"uri" => bq_uri, "embed" => embed}] = body["posts"]
    assert bq_uri == bq.uri
    assert embed["record"]["$type"] == "app.bsky.embed.record#viewRecord"
    assert embed["record"]["uri"] == p1.uri

    # actor likes: only for oneself
    body = xrpc!(conn, "app.bsky.feed.getActorLikes", %{"actor" => carol.did}, carol.did)
    assert feed_uris(body) == [{p2.uri, nil}, {p1.uri, nil}]
    assert hd(body["feed"])["post"]["viewer"]["like"]

    assert {400, %{"message" => "Profile not found"}} =
             xrpc_error(conn, "app.bsky.feed.getActorLikes", %{"actor" => carol.did}, bob.did)

    assert {400, _} = xrpc_error(conn, "app.bsky.feed.getActorLikes", %{"actor" => carol.did})

    # a blocked liker disappears from getLikes for the viewer
    write!(alice.did, [block(alice.did, carol.did, 8)])
    body = xrpc!(conn, "app.bsky.feed.getLikes", %{"uri" => p1.uri}, alice.did)
    assert Enum.map(body["likes"], & &1["actor"]["did"]) == [bob.did]
    # …and for everyone, since the like is between blocked parties (3p block)
    body = xrpc!(conn, "app.bsky.feed.getLikes", %{"uri" => p1.uri})
    assert Enum.map(body["likes"], & &1["actor"]["did"]) == [bob.did]
  end

  # ----------------------------------------------------------------- search

  test "searchPosts: substring search incl. CJK, from: filter, offset cursor", ctx do
    %{conn: conn, alice: alice, bob: bob} = ctx
    a1 = make_post(alice.did, "hello world from alice", 1)
    a2 = make_post(alice.did, "你好世界，早上好", 2)
    write!(alice.did, [a1, a2])
    b1 = make_post(bob.did, "Hello there", 3)
    b2 = make_post(bob.did, "世界 only", 4)
    write!(bob.did, [b1, b2])

    body = xrpc!(conn, "app.bsky.feed.searchPosts", %{"q" => "你好世界"})
    assert Enum.map(body["posts"], & &1["uri"]) == [a2.uri]
    assert body["hitsTotal"] == 1

    body = xrpc!(conn, "app.bsky.feed.searchPosts", %{"q" => "世界"})
    assert Enum.map(body["posts"], & &1["uri"]) == [b2.uri, a2.uri]

    # case-insensitive; author via from: (handle) and via the author param (did)
    body = xrpc!(conn, "app.bsky.feed.searchPosts", %{"q" => "hello"})
    assert Enum.map(body["posts"], & &1["uri"]) == [b1.uri, a1.uri]

    body = xrpc!(conn, "app.bsky.feed.searchPosts", %{"q" => "hello from:#{alice.handle}"})
    assert Enum.map(body["posts"], & &1["uri"]) == [a1.uri]

    body = xrpc!(conn, "app.bsky.feed.searchPosts", %{"q" => "hello", "author" => bob.did})
    assert Enum.map(body["posts"], & &1["uri"]) == [b1.uri]

    # offset cursor
    page = xrpc!(conn, "app.bsky.feed.searchPosts", %{"q" => "hello", "limit" => 1})
    assert Enum.map(page["posts"], & &1["uri"]) == [b1.uri]
    assert page["cursor"] == "1"

    page =
      xrpc!(conn, "app.bsky.feed.searchPosts", %{"q" => "hello", "limit" => 1, "cursor" => "1"})

    assert Enum.map(page["posts"], & &1["uri"]) == [a1.uri]
    refute page["cursor"]

    # LIKE metacharacters are literal
    assert xrpc!(conn, "app.bsky.feed.searchPosts", %{"q" => "%"})["posts"] == []
  end

  # ------------------------------------------------------------ custom feeds

  test "getFeed calls the generator with a service JWT; getFeedGenerator(s), getActorFeeds, getListFeed",
       ctx do
    %{conn: conn, alice: alice, bob: bob, carol: carol} = ctx
    a1 = make_post(alice.did, "a1", 1)
    a2 = make_post(alice.did, "a2", 2)
    write!(alice.did, [a1, a2])
    b1 = make_post(bob.did, "b1", 3)
    br = repost(bob.did, a1, 4)
    write!(bob.did, [b1, br])

    # carol's DID is the feed generator's, with a #bsky_fg service in its PLC document
    {:ok, _} =
      Aerox.PDS.PlcOps.update(
        carol.did,
        &put_in(&1, ["services", "bsky_fg"], %{
          "type" => "BskyFeedGenerator",
          "endpoint" => "https://feedgen.aerox.sola.town"
        }),
        "test",
        "test"
      )

    Aerox.Identity.invalidate(Aerox.AppView.Identity, carol.did)

    gen =
      create(
        alice.did,
        "app.bsky.feed.generator",
        %{"did" => carol.did, "displayName" => "Carol's feed", "createdAt" => at(5)},
        rkey: "carols"
      )

    write!(alice.did, [gen])

    Application.put_env(:aerox, Aerox.AppView.FeedGen, plug: StubFeedGen, allow_private: true)

    Application.put_env(:aerox, :test_feedgen, %{
      pid: self(),
      posts: [
        b1.uri,
        {:repost, a1.uri, br.uri},
        a2.uri,
        "at://#{alice.did}/app.bsky.feed.post/gone"
      ]
    })

    on_exit(fn ->
      Application.delete_env(:aerox, Aerox.AppView.FeedGen)
      Application.delete_env(:aerox, :test_feedgen)
    end)

    conn0 = conn
    conn = auth(conn, bob.did, "app.bsky.feed.getFeed")

    resp =
      get(
        conn,
        "/xrpc/app.bsky.feed.getFeed?" <>
          URI.encode_query(%{"feed" => gen.uri, "limit" => 10, "cursor" => "abc"})
      )

    body = json_response(resp, 200)

    assert {:ok, _} =
             Lexicon.validate_output(Lexicon.default_registry(), "app.bsky.feed.getFeed", body)

    assert get_resp_header(resp, "content-language") == ["en"]

    assert_received {:feedgen_called, claims, query}
    assert claims["aud"] == carol.did
    assert claims["iss"] == Config.service_did()
    assert claims["lxm"] == "app.bsky.feed.getFeedSkeleton"
    assert query == %{"feed" => gen.uri, "limit" => "10", "cursor" => "abc"}

    assert feed_uris(body) == [{b1.uri, nil}, {a1.uri, br.uri}, {a2.uri, nil}]
    assert body["cursor"] == "next-page"
    assert hd(body["feed"])["feedContext"] == "ctx"
    assert hd(body["feed"])["reqId"] == "req-1"
    assert Enum.at(body["feed"], 1)["reason"]["by"]["did"] == bob.did

    # anonymous works too; the JWT is the AppView's own either way
    body = xrpc!(conn0, "app.bsky.feed.getFeed", %{"feed" => gen.uri})
    assert_received {:feedgen_called, %{"iss" => "did:web:" <> _}, _}
    assert length(body["feed"]) == 3

    assert {400, %{"error" => "UnknownFeed"}} =
             xrpc_error(
               conn0,
               "app.bsky.feed.getFeed",
               %{"feed" => "at://#{alice.did}/app.bsky.feed.generator/nope"},
               bob.did
             )

    # generator views
    body = xrpc!(conn0, "app.bsky.feed.getFeedGenerator", %{"feed" => gen.uri}, bob.did)
    assert body["isOnline"] and body["isValid"]
    assert body["view"]["did"] == carol.did and body["view"]["displayName"] == "Carol's feed"
    assert body["view"]["creator"]["did"] == alice.did

    body =
      xrpc!(conn0, "app.bsky.feed.getFeedGenerators", [
        {"feeds", gen.uri},
        {"feeds", gen.uri <> "x"}
      ])

    assert [%{"uri" => gen_uri}] = body["feeds"]
    assert gen_uri == gen.uri

    body = xrpc!(conn0, "app.bsky.feed.getActorFeeds", %{"actor" => alice.handle})
    assert [%{"uri" => ^gen_uri}] = body["feeds"]

    assert xrpc!(conn0, "app.bsky.unspecced.getPopularFeedGenerators", %{}) == %{"feeds" => []}

    assert {501, %{"error" => "MethodNotImplemented"}} =
             xrpc_error(conn0, "app.bsky.feed.describeFeedGenerator", %{})

    # list feed: posts by the list's members (alice), not others
    list =
      create(carol.did, "app.bsky.graph.list", %{
        "name" => "friends",
        "purpose" => "app.bsky.graph.defs#curatelist",
        "createdAt" => at(6)
      })

    item =
      create(carol.did, "app.bsky.graph.listitem", %{
        "subject" => alice.did,
        "list" => list.uri,
        "createdAt" => at(6)
      })

    write!(carol.did, [list, item])
    body = xrpc!(conn0, "app.bsky.feed.getListFeed", %{"list" => list.uri}, bob.did)
    assert feed_uris(body) == [{a2.uri, nil}, {a1.uri, nil}]
  end

  test "atproto-accept-labelers selects labelers and is echoed back", %{conn: conn, alice: alice} do
    p = make_post(alice.did, "x", 1)
    write!(alice.did, [p])

    resp =
      conn
      |> put_req_header(
        "atproto-accept-labelers",
        "did:plc:labelerone;redact, did:web:two.example"
      )
      |> get("/xrpc/app.bsky.feed.getPosts?uris=#{URI.encode_www_form(p.uri)}")

    assert json_response(resp, 200)["posts"] |> length() == 1

    assert get_resp_header(resp, "atproto-content-labelers") ==
             ["did:plc:labelerone;redact,did:web:two.example"]
  end
end
