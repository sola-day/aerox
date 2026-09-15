defmodule Aerox.Jetstream.WriterTest do
  @moduledoc "The log: seqs and witnessed times, blocks, reads across archive and pending rows, sealing, recovery."
  use Aerox.JetstreamCase, async: false
  import Ecto.Query
  alias Aerox.Jetstream.{Repo, Segment}
  alias Aerox.Jetstream.Schema.{EventRow, Tombstone}

  test "appends get increasing seqs; full blocks flush to the active file; reads span both" do
    {:ok, rows} = Writer.append(for(n <- 1..7, do: create("did:plc:writer", n)), cursor: 42)
    seqs = Enum.map(rows, & &1.seq)
    assert seqs == Enum.sort(seqs) and length(Enum.uniq(seqs)) == 7
    assert Enum.all?(rows, &(&1.witnessed_at > 0))
    assert Aerox.Jetstream.Store.get("relay_cursor") == 42

    # 7 rows with 3-row blocks: two blocks flushed, one row pending
    assert %{blocks: [%{event_count: 3}, %{event_count: 3}]} = Manifest.active()
    assert Repo.aggregate(EventRow, :count) == 1

    read = read_all(hd(seqs))
    assert Enum.map(read, & &1.seq) == seqs
    assert Enum.map(read, & &1.payload) == Enum.map(rows, & &1.payload)

    # from the middle of a block, and past the tip
    assert {:ok, [%{seq: s}], _} = Tail.read_from(Enum.at(seqs, 2), 1)
    assert s == Enum.at(seqs, 2)
    assert {:ok, [], _} = Tail.read_from(List.last(seqs) + 1, 10)

    {:ok, more} = Writer.append([create("did:plc:writer", 8)])
    assert hd(more).seq > List.last(seqs)
    assert hd(more).witnessed_at >= List.last(rows).witnessed_at
  end

  test "rotate seals the active segment in place; the manifest and the file agree", %{dir: dir} do
    {:ok, rows} = Writer.append(for(n <- 1..7, do: create("did:plc:seal#{rem(n, 2)}", n)))
    :ok = Writer.rotate()

    assert [seg] = Manifest.sealed()
    assert seg.header.event_count == 7 and seg.header.block_count == 3
    assert seg.header.min_seq == hd(rows).seq and seg.header.max_seq == List.last(rows).seq
    assert %{idx: 1, blocks: []} = Manifest.active()

    path = Path.join([dir, "segments", Segment.filename(0)])
    assert {:ok, parsed} = Segment.parse(File.read!(path))
    assert parsed.header.checksum == seg.header.checksum
    assert Aerox.Jetstream.Gloom.member?(parsed.segment_bloom, "did:plc:seal0")
    assert parsed.collections == ["app.bsky.feed.post"]

    assert Enum.map(read_all(hd(rows).seq), & &1.seq) == Enum.map(rows, & &1.seq)
  end

  test "restart: pending rows survive, the active file is re-read, a torn tail is cut", %{
    dir: dir
  } do
    {:ok, rows} = Writer.append(for(n <- 1..5, do: create("did:plc:crash", n)))
    stop_supervised!(Writer)

    active = Path.join([dir, "segments", Segment.filename(0)])
    File.write!(active, <<9, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3>>, [:append])

    start_supervised!(Writer)
    assert %{blocks: [%{event_count: 3}]} = Manifest.active()
    assert Enum.map(read_all(hd(rows).seq), & &1.seq) == Enum.map(rows, & &1.seq)

    # the file ends at the last whole frame again
    [%{offset: off, compressed_size: size}] = Manifest.active().blocks
    assert File.stat!(active).size == off + 8 + size

    # an active file is recognised as active, not as a corrupt segment
    assert {:error, :active} = Segment.decode_header(binary_part(File.read!(active), 0, 256))
    :ok = Manifest.reload()
    assert Manifest.sealed() == []

    :ok = Writer.rotate()
    assert [%{header: %{event_count: 5}}] = Manifest.sealed()
  end

  test "deletes, updates, account deletions and syncs leave tombstones" do
    del = %Event{
      kind: :delete,
      did: "did:plc:t",
      collection: "app.bsky.feed.post",
      rkey: "a",
      rev: "3kaaaaaaaaa22"
    }

    upd = %{create("did:plc:t", 1) | kind: :update, rkey: "b"}

    gone = %Event{
      kind: :account,
      did: "did:plc:t",
      payload:
        Aerox.ATProto.DagCBOR.encode(%{
          "did" => "did:plc:t",
          "active" => false,
          "status" => "deleted",
          "seq" => 1,
          "time" => "2026-09-15T00:00:00.000Z"
        })
    }

    paused = %Event{
      kind: :account,
      did: "did:plc:t",
      payload:
        Aerox.ATProto.DagCBOR.encode(%{
          "did" => "did:plc:t",
          "active" => false,
          "status" => "deactivated",
          "seq" => 2,
          "time" => "2026-09-15T00:00:00.000Z"
        })
    }

    sync = %Event{
      kind: :sync,
      did: "did:plc:u",
      rev: "3kaaaaaaaaa22",
      payload: Aerox.ATProto.DagCBOR.encode(%{"did" => "did:plc:u"})
    }

    {:ok, [d, u, g, _p, s]} = Writer.append([del, upd, gone, paused, sync])

    assert from(t in Tombstone, order_by: t.seq, select: {t.seq, t.scope, t.key}) |> Repo.all() ==
             [
               {d.seq, "uri", "at://did:plc:t/app.bsky.feed.post/a"},
               {u.seq, "uri", "at://did:plc:t/app.bsky.feed.post/b"},
               {g.seq, "did", "did:plc:t"},
               {s.seq, "did", "did:plc:u"}
             ]
  end
end
