defmodule Aerox.AppView.IndexingTest do
  @moduledoc """
  VERIFICATION §5 AppView: the plugins driven by real records — accounts
  created on our PDS, records written through the PDS write path, and the
  resulting firehose events fed to the ingest indexer exactly as the
  Broadway pipeline would.
  """
  use Aerox.DataCase, async: false
  import Ecto.Query
  alias Aerox.PDS.Records
  alias Aerox.PDS.Records.Prepare
  alias Aerox.PDS.Sequencer, as: PdsSeq
  alias Aerox.AppView.Ingest.Indexer
  alias Aerox.AppView.Repo
  alias Aerox.AppView.Schema, as: S

  setup do
    Aerox.RateLimit.reset()
    # the PDS sequencer is shared across tests: index only what this test produces
    since = PdsSeq.current() || 0
    {:ok, alice} = signup("alice-av")
    {:ok, bob} = signup("bob-av")
    {:ok, alice: alice, bob: bob, since: since}
  end

  defp signup(name) do
    Aerox.PDS.Signup.create(%{
      handle: "#{name}.aerox.sola.town",
      email: "#{name}@example.com",
      password: "pw-pw-pw-pw"
    })
  end

  # writes through the PDS, then indexes every new firehose event
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

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  test "signup events index the actor with its verified handle", %{alice: alice, since: since} do
    ingest_since(since)
    actor = Repo.get!(S.Actor, alice.did)
    assert actor.handle == "alice-av.aerox.sola.town"
    assert actor.upstream_status == "active"
    assert Repo.get(S.ActorSync, alice.did).repo_rev != nil
  end

  test "posts, replies, likes, reposts, follows, quotes: rows, aggregates, feed items, notifications",
       ctx do
    %{alice: alice, bob: bob} = ctx
    ingest_since(ctx.since)

    # alice posts; bob follows alice, likes, reposts, replies and quotes
    post =
      create(alice.did, "app.bsky.feed.post", %{"text" => "hello world", "createdAt" => now()})

    write!(alice.did, [post])
    assert %S.Post{text: "hello world", creator: creator} = Repo.get!(S.Post, post.uri)
    assert creator == alice.did
    assert Repo.get!(S.FeedItem, post.uri).type == "post"
    assert Repo.get!(S.ProfileAgg, alice.did).posts_count == 1

    follow =
      create(bob.did, "app.bsky.graph.follow", %{"subject" => alice.did, "createdAt" => now()})

    like =
      create(bob.did, "app.bsky.feed.like", %{
        "subject" => %{"uri" => post.uri, "cid" => to_string(post.cid)},
        "createdAt" => now()
      })

    repost =
      create(bob.did, "app.bsky.feed.repost", %{
        "subject" => %{"uri" => post.uri, "cid" => to_string(post.cid)},
        "createdAt" => now()
      })

    write!(bob.did, [follow, like, repost])

    assert Repo.get!(S.ProfileAgg, alice.did).followers_count == 1
    assert Repo.get!(S.ProfileAgg, bob.did).follows_count == 1
    agg = Repo.get!(S.PostAgg, post.uri)
    assert agg.like_count == 1 and agg.repost_count == 1
    assert Repo.get!(S.FeedItem, repost.uri).post_uri == post.uri

    reply =
      create(bob.did, "app.bsky.feed.post", %{
        "text" => "hi alice",
        "createdAt" => now(),
        "reply" => %{
          "root" => %{"uri" => post.uri, "cid" => to_string(post.cid)},
          "parent" => %{"uri" => post.uri, "cid" => to_string(post.cid)}
        }
      })

    quote_post =
      create(bob.did, "app.bsky.feed.post", %{
        "text" => "look at this",
        "createdAt" => now(),
        "embed" => %{
          "$type" => "app.bsky.embed.record",
          "record" => %{"uri" => post.uri, "cid" => to_string(post.cid)}
        }
      })

    write!(bob.did, [reply, quote_post])

    agg = Repo.get!(S.PostAgg, post.uri)
    assert agg.reply_count == 1 and agg.quote_count == 1
    assert Repo.get!(S.Post, reply.uri).reply_parent == post.uri
    refute Repo.get!(S.Post, reply.uri).invalid_reply_root
    assert Repo.get!(S.Quote, quote_post.uri).subject == post.uri
    assert Repo.get!(S.PostEmbedRecord, quote_post.uri).embed_uri == post.uri

    reasons =
      Repo.all(
        from(n in S.Notification,
          where: n.did == ^alice.did,
          order_by: [asc: n.id],
          select: {n.reason, n.author}
        )
      )

    assert reasons == [
             {"follow", bob.did},
             {"like", bob.did},
             {"repost", bob.did},
             {"reply", bob.did},
             {"quote", bob.did}
           ]

    assert Repo.all(from(n in S.Notification, where: n.did == ^bob.did)) == []

    # a second like of the same post is a duplicate: no second notification, count stays 1
    like2 =
      create(bob.did, "app.bsky.feed.like", %{
        "subject" => %{"uri" => post.uri, "cid" => to_string(post.cid)},
        "createdAt" => now()
      })

    write!(bob.did, [like2])
    assert Repo.get!(S.PostAgg, post.uri).like_count == 1
    assert Repo.get!(S.DuplicateRecord, like2.uri).duplicate_of == like.uri
    assert length(Repo.all(from(n in S.Notification, where: n.reason == "like"))) == 1

    # deleting the original like promotes the duplicate and keeps the count
    {:ok, d} = Prepare.delete(bob.did, "app.bsky.feed.like", like.rkey)
    write!(bob.did, [d])
    assert Repo.get!(S.PostAgg, post.uri).like_count == 1
    assert Repo.get(S.Like, like2.uri) != nil
    assert Repo.get(S.DuplicateRecord, like2.uri) == nil

    # deleting the post removes its feed item, quote counts, and its notifications
    {:ok, d} = Prepare.delete(alice.did, "app.bsky.feed.post", post.rkey)
    write!(alice.did, [d])
    assert Repo.get(S.Post, post.uri) == nil
    assert Repo.get(S.FeedItem, post.uri) == nil
    assert Repo.get!(S.ProfileAgg, alice.did).posts_count == 0
  end

  test "profile, thread gate and account status", ctx do
    %{alice: alice, bob: bob} = ctx
    ingest_since(ctx.since)

    profile =
      create(
        alice.did,
        "app.bsky.actor.profile",
        %{"displayName" => "Alice", "description" => "hello"},
        rkey: "self"
      )

    write!(alice.did, [profile])
    assert %S.Profile{display_name: "Alice"} = Repo.get_by!(S.Profile, creator: alice.did)

    # a gated root: nobody may reply (allow: [])
    root = create(alice.did, "app.bsky.feed.post", %{"text" => "gated", "createdAt" => now()})

    gate =
      create(
        alice.did,
        "app.bsky.feed.threadgate",
        %{"post" => root.uri, "allow" => [], "createdAt" => now()},
        rkey: root.rkey
      )

    write!(alice.did, [root, gate])
    assert Repo.get!(S.Post, root.uri).has_thread_gate == true

    reply =
      create(bob.did, "app.bsky.feed.post", %{
        "text" => "sneaky",
        "createdAt" => now(),
        "reply" => %{
          "root" => %{"uri" => root.uri, "cid" => to_string(root.cid)},
          "parent" => %{"uri" => root.uri, "cid" => to_string(root.cid)}
        }
      })

    write!(bob.did, [reply])
    assert Repo.get!(S.Post, reply.uri).violates_thread_gate == true
    # no reply notification, and the gated reply does not count
    assert Repo.all(from(n in S.Notification, where: n.did == ^alice.did and n.reason == "reply")) ==
             []

    assert (Repo.get(S.PostAgg, root.uri) || %{reply_count: 0}).reply_count == 0

    # account deactivation and deletion through the firehose
    :ok =
      Indexer.process("#account", %{
        "did" => bob.did,
        "active" => false,
        "status" => "deactivated",
        "time" => now()
      })

    assert Repo.get!(S.Actor, bob.did).upstream_status == "deactivated"

    :ok =
      Indexer.process("#account", %{
        "did" => bob.did,
        "active" => false,
        "status" => "deleted",
        "time" => now()
      })

    assert Repo.get(S.Post, reply.uri) == nil
    assert Repo.all(from(r in S.Record, where: r.did == ^bob.did)) == []
  end
end
