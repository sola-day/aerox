defmodule Aerox.Jetstream.PipelineTest do
  @moduledoc """
  From the Relay to the archive: a real account's events through the ingest,
  a resync from its PDS, the bootstrap backfill and merge, and compaction of
  superseded rows in sealed segments.
  """
  use Aerox.JetstreamCase, async: false
  alias Aerox.ATProto.DagCBOR
  alias Aerox.Jetstream.{Bootstrap, Compactor, Ingest, Repos, Segment, Store}
  alias Aerox.PDS.Sequencer, as: PdsSeq

  setup do
    Aerox.RateLimit.reset()
    :ok
  end

  defp account(name) do
    before = PdsSeq.current() || 0

    {:ok, %{did: did}} =
      Aerox.PDS.Signup.create(%{
        handle: "#{name}.test",
        email: "#{name}@example.com",
        password: "pw-pw-pw-pw"
      })

    {did, before}
  end

  defp post(did, text) do
    {:ok, w} =
      Aerox.PDS.Records.Prepare.create(did, "app.bsky.feed.post", %{
        "$type" => "app.bsky.feed.post",
        "text" => text,
        "createdAt" => "2026-09-15T00:00:00.000Z"
      })

    {:ok, commit} = Aerox.PDS.Records.process_writes(did, [w])
    {w, commit}
  end

  defp pds_events(since), do: since |> PdsSeq.range(1000) |> Enum.map(&PdsSeq.Events.to_frame/1)

  defp feed(events, phase) do
    for {type, body} <- events, do: Ingest.handle_event(type, body, body["seq"], phase)
  end

  test "steady state: the relay's events for an account become rows, the cursor advances" do
    {did, before} = account("js-live")
    {w, _} = post(did, "hello jetstream")
    events = pds_events(before)
    feed(events, "steady_state")

    rows = read_all() |> Enum.filter(&(&1.did == did))
    assert [:identity, :account, :sync, :create] == Enum.map(rows, & &1.kind)
    create = List.last(rows)
    assert {create.collection, create.rkey} == {"app.bsky.feed.post", w.rkey}
    assert {:ok, %{"text" => "hello jetstream"}} = DagCBOR.decode(create.payload)
    assert Store.get("relay_cursor") == events |> List.last() |> elem(1) |> Map.get("seq")
  end

  test "a resync appends a synthetic #sync and the repo's records as create_resync" do
    {did, _} = account("js-resync")
    post(did, "one")
    post(did, "two")

    assert :ok = Repos.resync(did)
    rows = read_all() |> Enum.filter(&(&1.did == did))
    assert [%{kind: :sync} | records] = rows
    assert Enum.all?(records, &(&1.kind == :create_resync))

    assert records |> Enum.map(&elem(DagCBOR.decode(&1.payload), 1)["text"]) |> Enum.sort() == [
             "one",
             "two"
           ]

    assert %{status: "synchronized"} =
             Aerox.Jetstream.Repo.get(Aerox.Jetstream.Schema.RepoRow, did)
  end

  test "bootstrap: crawl the relay, backfill, merge the captured tail without what the snapshot covers" do
    Store.put("phase", "bootstrap")
    {did, before} = account("js-boot")
    {_old, _} = post(did, "before the snapshot")
    early = pds_events(before)

    # the relay knows the account
    {:ok, host} = Aerox.Relay.Hosts.create("pds.aerox.sola.town", false)
    for {t, b} <- early, do: Aerox.Relay.Ingest.process(host, t, b)

    # the live tail captured during bootstrap starts with those same events
    feed(early, "bootstrap")

    :ok = Bootstrap.crawl()
    assert {:ok, snapshot_rev} = Repos.backfill(did)

    # an event after the snapshot, also captured
    later_since = PdsSeq.current()
    {w2, _} = post(did, "after the snapshot")
    feed(pds_events(later_since), "bootstrap")

    assert Enum.all?(
             Stream.repeatedly(&Bootstrap.merge_step/0) |> Enum.take_while(&(&1 == :more)),
             &(&1 == :more)
           )

    assert Store.steady_state?()

    rows = read_all() |> Enum.filter(&(&1.did == did))
    creates = Enum.filter(rows, &(&1.kind == :create))
    texts = Enum.map(creates, &elem(DagCBOR.decode(&1.payload), 1)["text"])

    # the snapshot's post once (not again from the captured tail), the later post once
    assert Enum.sort(texts) == ["after the snapshot", "before the snapshot"]
    assert Enum.any?(creates, &(&1.rkey == w2.rkey and &1.rev > snapshot_rev))
    assert Enum.count(rows, &(&1.kind == :identity)) >= 1
  end

  @tag block: 2
  test "compaction drops superseded rows from sealed segments, keeps markers and block topology" do
    a = create("did:plc:compact", 1)
    b = create("did:plc:compact", 2)
    {:ok, [ra, rb]} = Writer.append([a, b])
    {:ok, [upd]} = Writer.append([%{create("did:plc:compact", 3) | kind: :update, rkey: b.rkey}])

    {:ok, [del]} =
      Writer.append([
        %Event{
          kind: :delete,
          did: "did:plc:compact",
          collection: a.collection,
          rkey: a.rkey,
          rev: a.rev
        }
      ])

    :ok = Writer.rotate()

    [seg] = Manifest.sealed()
    assert seg.header.event_count == 4

    assert {:ok, %{segments: 1, rows_dropped: 2}} = Compactor.pass()
    [after_seg] = Manifest.sealed()
    assert after_seg.header.event_count == 2
    assert after_seg.header.block_count == seg.header.block_count

    assert {after_seg.header.min_seq, after_seg.header.max_seq} ==
             {seg.header.min_seq, seg.header.max_seq}

    assert after_seg.header.checksum != seg.header.checksum
    assert {:ok, _} = Segment.parse(File.read!(after_seg.path))

    kept = read_all(ra.seq)
    assert Enum.map(kept, & &1.seq) == [upd.seq, del.seq]
    refute Enum.any?(kept, &(&1.seq in [ra.seq, rb.seq]))

    # a second pass has nothing to do
    assert {:ok, %{segments: 0}} = Compactor.pass()
  end
end
