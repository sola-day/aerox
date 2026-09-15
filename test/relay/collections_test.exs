defmodule Aerox.Relay.CollectionsTest do
  @moduledoc """
  `com.atproto.sync.listReposByCollection` on the relay: the directory is fed by
  verified commits, completed by a `describeRepo` crawl, paged by first sight,
  and forgets deleted accounts.
  """
  use AeroxWeb.ConnCase, async: false
  import Ecto.Query
  alias Aerox.PDS.Sequencer, as: PdsSeq
  alias Aerox.Relay.{Accounts, Collections, Hosts, Ingest, Repo}
  alias Aerox.Relay.Schema.RepoCollection

  setup %{conn: conn} do
    Aerox.RateLimit.reset()
    {:ok, host} = Hosts.create("pds.aerox.sola.town", false)
    {:ok, conn: %{conn | host: Aerox.Relay.Config.hostname()}, host: host}
  end

  defp relay_account(host, name, collections) do
    before = PdsSeq.current() || 0

    {:ok, %{did: did}} =
      Aerox.PDS.Signup.create(%{
        handle: "#{name}.aerox.sola.town",
        email: "#{name}@example.com",
        password: "pw-pw-pw-pw"
      })

    for c <- collections do
      {:ok, w} =
        Aerox.PDS.Records.Prepare.create(did, c, %{
          "$type" => c,
          "text" => "x",
          "subject" => did,
          "createdAt" => "2026-09-15T00:00:00.000Z"
        })

      {:ok, _} = Aerox.PDS.Records.process_writes(did, [w])
    end

    for row <- PdsSeq.range(before, 100) do
      {type, body} = PdsSeq.Events.to_frame(row)
      assert :ok = Ingest.process(host, type, body)
    end

    did
  end

  defp list(conn, query) do
    conn |> get("/xrpc/com.atproto.sync.listReposByCollection?" <> URI.encode_query(query))
  end

  test "commits feed the directory; paging follows first sight", %{conn: conn, host: host} do
    a = relay_account(host, "coll-a", ["app.bsky.feed.post", "app.bsky.graph.follow"])
    b = relay_account(host, "coll-b", ["app.bsky.feed.post"])

    assert list(conn, collection: "app.bsky.feed.post") |> json_response(200) ==
             %{"repos" => [%{"did" => a}, %{"did" => b}]}

    assert list(conn, collection: "app.bsky.graph.follow") |> json_response(200) ==
             %{"repos" => [%{"did" => a}]}

    assert list(conn, collection: "app.bsky.feed.like") |> json_response(200) == %{"repos" => []}

    page = list(conn, collection: "app.bsky.feed.post", limit: 1) |> json_response(200)
    assert page["repos"] == [%{"did" => a}]

    assert list(conn, collection: "app.bsky.feed.post", limit: 1, cursor: page["cursor"])
           |> json_response(200)
           |> Map.get("repos") == [%{"did" => b}]

    assert list(conn, collection: "app.bsky.feed.post", cursor: "nope") |> json_response(400)
    assert list(conn, %{}) |> json_response(400)

    # a taken-down account is not listed
    :ok = Accounts.update_local_status(Accounts.get(b).uid, "takendown")

    assert list(conn, collection: "app.bsky.feed.post") |> json_response(200) ==
             %{"repos" => [%{"did" => a}]}

    # a deleted account leaves the directory
    assert :ok =
             Ingest.process(host, "#account", %{
               "did" => a,
               "active" => false,
               "status" => "deleted",
               "seq" => 1,
               "time" => "2026-09-15T00:00:00.000Z"
             })

    refute Repo.exists?(from(r in RepoCollection, where: r.did == ^a))
  end

  test "a describeRepo crawl completes and corrects an account's set", %{host: host} do
    did = relay_account(host, "coll-crawl", ["app.bsky.feed.post"])

    # a profile written before the relay saw the account, and a stale entry
    {:ok, w} =
      Aerox.PDS.Records.Prepare.create(
        did,
        "app.bsky.actor.profile",
        %{
          "$type" => "app.bsky.actor.profile",
          "displayName" => "x"
        },
        rkey: "self"
      )

    {:ok, _} = Aerox.PDS.Records.process_writes(did, [w])

    Repo.insert_all(RepoCollection, [
      %{collection: "com.example.gone", did: did, inserted_at: ~U[2026-01-01 00:00:00.000000Z]}
    ])

    assert Collections.uncrawled(1000) |> Enum.member?(did)
    assert :ok = Collections.crawl(did)

    collections =
      from(r in RepoCollection,
        where: r.did == ^did,
        select: r.collection,
        order_by: r.collection
      )
      |> Repo.all()

    assert collections == ["app.bsky.actor.profile", "app.bsky.feed.post"]
    refute Collections.uncrawled(1000) |> Enum.member?(did)
  end
end
