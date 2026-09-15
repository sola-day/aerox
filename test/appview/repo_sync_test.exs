defmodule Aerox.AppView.RepoSyncTest do
  @moduledoc """
  Sync spec, "Reliable Repository Synchronization" and "Record-Level
  Synchronization": the AppView tracks each repo's rev and data root, applies
  only commits that follow on, re-synchronises a repo whose chain breaks from
  its CAR, and queues what arrives meanwhile.
  """
  use Aerox.DataCase, async: false
  use Oban.Testing, repo: Aerox.AppView.Repo, prefix: "appview"
  import Aerox.AppViewHelpers
  import Ecto.Query
  alias Aerox.ATProto.TID
  alias Aerox.AppView.{Backfill, Indexing, RepoSync}
  alias Aerox.AppView.Ingest.Indexer
  alias Aerox.AppView.Schema.{ActorSyncPending, Record}
  alias Aerox.PDS.Records
  alias Aerox.PDS.Sequencer, as: PdsSeq

  setup do
    Aerox.RateLimit.reset()
    :ok
  end

  # a write on the PDS, and its firehose events — not delivered
  defp pds_write(did, writes) do
    before = PdsSeq.current() || 0
    {:ok, commit} = Records.process_writes(did, writes)
    events = before |> PdsSeq.range(100) |> Enum.map(&PdsSeq.Events.to_frame/1)
    {commit, events}
  end

  defp post(did, text),
    do: create(did, "app.bsky.feed.post", %{"text" => text, "createdAt" => now()})

  defp deliver(events), do: Enum.map(events, fn {type, body} -> Indexer.process(type, body) end)

  defp indexed?(uri), do: Aerox.AppView.Repo.exists?(from(r in Record, where: r.uri == ^uri))

  defp fresh_account(name) do
    before = PdsSeq.current() || 0
    account = signup(name)
    ingest_since(before)
    account
  end

  test "a new repo starts synchronised at its first commit, with rev and data root" do
    %{did: did} = fresh_account("rs-new")
    root = Records.root(did)
    row = RepoSync.get(did)
    assert row.status == "synchronized"
    assert row.repo_rev == root.rev
    assert row.commit_cid == to_string(root.cid)
    assert is_binary(row.data_cid)

    p = post(did, "one")
    {commit, events} = pds_write(did, [p])
    assert deliver(events) == [:ok]
    assert RepoSync.get(did).repo_rev == commit.rev
    assert indexed?(p.uri)

    # delivered twice (a reconnect replay): at or below the last rev is ignored
    assert [{:skip, {:old_rev, _, _}}] = deliver(events)
  end

  test "a broken chain desynchronises the repo; the backfill reconciles it with its CAR" do
    %{did: did} = fresh_account("rs-gap")
    p1 = post(did, "kept until deleted in the gap")
    {_, events} = pds_write(did, [p1])
    assert deliver(events) == [:ok]

    # lost in transit: p1 deleted, p2 created
    {:ok, del} = Records.Prepare.delete(did, "app.bsky.feed.post", p1.rkey)
    {_, _lost} = pds_write(did, [del])
    p2 = post(did, "never delivered")
    {_, _lost} = pds_write(did, [p2])

    # p3 does not follow on from what the AppView holds
    p3 = post(did, "after the gap")
    {_, events} = pds_write(did, [p3])
    assert [{:skip, {:desynchronized, {:since_mismatch, _, _}}}] = deliver(events)
    assert RepoSync.get(did).status == "desynchronized"
    assert_enqueued(worker: Backfill, args: %{"did" => did})
    refute indexed?(p3.uri)

    # while desynchronised, events are dropped: the CAR will contain them
    p4 = post(did, "during the outage")
    {commit4, events} = pds_write(did, [p4])
    assert [{:skip, :desynchronized}] = deliver(events)

    assert :ok = perform_job(Backfill, %{"did" => did})

    row = RepoSync.get(did)
    assert row.status == "synchronized" and row.repo_rev == commit4.rev
    refute indexed?(p1.uri)
    assert indexed?(p2.uri) and indexed?(p3.uri) and indexed?(p4.uri)

    # and live indexing carries on from the CAR's state
    p5 = post(did, "back to normal")
    {_, events} = pds_write(did, [p5])
    assert deliver(events) == [:ok]
    assert indexed?(p5.uri)
  end

  test "events during a backfill are queued, then replayed in order; a break in the queue resyncs" do
    %{did: did} = fresh_account("rs-queue")
    before = RepoSync.get(did)
    car_state = %{rev: before.repo_rev, commit_cid: before.commit_cid, data_cid: before.data_cid}

    :ok = RepoSync.begin_backfill(did)
    p1 = post(did, "queued one")
    {_, e1} = pds_write(did, [p1])
    p2 = post(did, "queued two")
    {c2, e2} = pds_write(did, [p2])
    assert deliver(e1 ++ e2) == [:ok, :ok]
    assert RepoSync.get(did).status == "in_progress"

    assert Aerox.AppView.Repo.aggregate(from(p in ActorSyncPending, where: p.did == ^did), :count) ==
             2

    refute indexed?(p1.uri)

    # the CAR predates both: both replay
    assert :ok = RepoSync.finish_backfill(did, car_state, &Indexer.replay_commit/1)
    assert indexed?(p1.uri) and indexed?(p2.uri)
    row = RepoSync.get(did)
    assert row.status == "synchronized" and row.repo_rev == c2.rev

    # a gap inside the queue
    state2 = %{rev: row.repo_rev, commit_cid: row.commit_cid, data_cid: row.data_cid}
    :ok = RepoSync.begin_backfill(did)
    {_, _lost} = pds_write(did, [post(did, "lost")])
    p4 = post(did, "queued after a loss")
    {_, e4} = pds_write(did, [p4])
    assert deliver(e4) == [:ok]
    assert :resync = RepoSync.finish_backfill(did, state2, &Indexer.replay_commit/1)
    assert RepoSync.get(did).status == "desynchronized"
    refute indexed?(p4.uri)

    assert Aerox.AppView.Repo.aggregate(from(p in ActorSyncPending, where: p.did == ^did), :count) ==
             0
  end

  test "#sync: a confirmation is a no-op, a newer commit resets the repo" do
    before = PdsSeq.current() || 0
    %{did: did} = signup("rs-sync")
    signup_events = before |> PdsSeq.range(100) |> Enum.map(&PdsSeq.Events.to_frame/1)
    assert Enum.all?(deliver(signup_events), &(&1 == :ok))

    # the signup's own #sync restates the state just reached
    {"#sync", signup_sync} = Enum.find(signup_events, &match?({"#sync", _}, &1))
    assert Indexer.process("#sync", signup_sync) == :ok
    assert RepoSync.get(did).status == "synchronized"

    # a #sync naming a newer commit than the one we hold is a reset
    {_, [{"#commit", commit}]} = pds_write(did, [post(did, "only the sync will say")])

    reset =
      Map.take(commit, ["rev", "blocks", "seq", "time"]) |> Map.put("did", did)

    assert {:skip, {:desynchronized, {:sync_reset, _}}} = Indexer.process("#sync", reset)
    assert RepoSync.get(did).status == "desynchronized"
    assert_enqueued(worker: Backfill, args: %{"did" => did})
  end

  test "inactive accounts and future revs are ignored" do
    %{did: did} = fresh_account("rs-inactive")
    :ok = Indexing.update_actor_status(did, upstream_status: "deactivated")
    p = post(did, "while deactivated")
    {_, events} = pds_write(did, [p])
    assert [{:skip, {:inactive, "deactivated"}}] = deliver(events)
    refute indexed?(p.uri)

    future = TID.from_time(System.os_time(:microsecond) + 3_600_000_000, 0)

    assert {:skip, {:future_rev, ^future}} =
             RepoSync.on_commit(did, %{}, %{rev: future, commit_cid: "", data_cid: ""}, fn ->
               flunk("applied")
             end)
  end
end
