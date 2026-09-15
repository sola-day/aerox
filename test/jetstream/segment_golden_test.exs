defmodule Aerox.Jetstream.SegmentGoldenTest do
  @moduledoc """
  The segment format against jetstream's own fixtures (segment/testdata at
  58c4d7f): the golden block, the golden two-event seal, and a legacy segment
  with fixed-size blooms. Compressed frames are libzstd's rather than
  klauspost's, so the checks are on what the format pins: the column layout,
  the header, the XXH3 checksum, gloom's serialized filters bit for bit, and
  the collection index body.
  """
  use Aerox.GoldenCase, async: true
  alias Aerox.Jetstream.{Block, Event, Gloom, Segment}

  defp golden(name), do: File.read!(golden_path("jetstream/" <> name))

  test "golden_block.bin decodes to upstream's pinned events, and re-encodes to the same columns" do
    assert {:ok, events, usize} = Block.decompress(golden("golden_block.bin"))

    expected = [
      %Event{
        seq: 1,
        witnessed_at: 1_700_000_000_000_000,
        indexed_at: 0,
        kind: :create,
        did: "did:plc:abcdefghijklmnopqrstuvwx",
        collection: "app.bsky.feed.post",
        rkey: "3l3qo2vuowo2b",
        rev: "3l3qo2vutsw2b",
        payload: <<0xA1, 0x65, 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x05>>
      },
      %Event{
        seq: 2,
        witnessed_at: 1_700_000_001_000_000,
        indexed_at: 1_700_000_000_500_000,
        kind: :identity,
        did: "did:web:example.com"
      },
      %Event{
        seq: 3,
        witnessed_at: 1_700_000_002_000_000,
        indexed_at: 0,
        kind: :delete,
        did: "did:plc:zzzzzzzzzzzzzzzzzzzzzzzz",
        collection: "app.bsky.feed.like",
        rkey: "3l3qo2vuowo2c",
        rev: "3l3qo2vutsw2c"
      }
    ]

    assert events == expected
    body = Block.encode(expected)
    assert byte_size(body) == usize
    assert {:ok, ^expected, ^usize} = Block.decompress(Block.zstd(body))
  end

  test "golden_seal.bin: header, checksum, blooms and collection index; our seal matches it" do
    file = golden("golden_seal.bin")
    assert {:ok, parsed} = Segment.parse(file)
    h = parsed.header

    assert %{
             block_count: 1,
             event_count: 2,
             unique_did_count: 2,
             min_seq: 1,
             max_seq: 2,
             min_witnessed_at: 100,
             max_witnessed_at: 200
           } = h

    assert {:ok, frame} = Segment.frame(file, parsed, 0)
    assert {:ok, [e1, e2], _} = Block.decompress(frame)
    assert {e1.did, e2.did, e2.indexed_at} == {"did:plc:a", "did:plc:b", 250}

    assert Gloom.member?(parsed.segment_bloom, "did:plc:a") and
             Gloom.member?(parsed.segment_bloom, "did:plc:b")

    assert parsed.collections == ["app.bsky.feed.post", "app.bsky.feed.like"]
    assert parsed.collection_counts == [1, 1]
    assert parsed.block_collections == [[0, 1]]

    # the same events sealed by us: identical metadata, identical filters
    {frame2, usize} = Block.compress([e1, e2])

    {ours, our_header} =
      Segment.seal([%{frame: frame2, events: [e1, e2], uncompressed_size: usize}])

    assert {:ok, ours_parsed} = Segment.parse(ours)

    for key <- [
          :version,
          :block_count,
          :event_count,
          :unique_did_count,
          :min_seq,
          :max_seq,
          :min_witnessed_at,
          :max_witnessed_at
        ] do
      assert Map.fetch!(our_header, key) == Map.fetch!(h, key), "header #{key}"
    end

    bytes = fn f, parsed, from, to ->
      binary_part(
        f,
        Map.fetch!(parsed.header, from),
        Map.fetch!(parsed.header, to) - Map.fetch!(parsed.header, from)
      )
    end

    assert bytes.(ours, ours_parsed, :did_bloom_offset, :block_did_bloom_offset) ==
             bytes.(file, parsed, :did_bloom_offset, :block_did_bloom_offset)

    assert bytes.(ours, ours_parsed, :block_did_bloom_offset, :collection_index_offset) ==
             bytes.(file, parsed, :block_did_bloom_offset, :collection_index_offset)

    assert {ours_parsed.collections, ours_parsed.collection_counts, ours_parsed.block_collections} ==
             {parsed.collections, parsed.collection_counts, parsed.block_collections}

    assert Enum.map(ours_parsed.blocks, &Map.drop(&1, [:offset, :compressed_size])) ==
             Enum.map(parsed.blocks, &Map.drop(&1, [:offset, :compressed_size]))
  end

  test "a legacy segment: every row's DID is in its block's filter and the segment's; the index agrees with the rows" do
    file = golden("legacy_fixed4096_blooms.jss")
    assert {:ok, parsed} = Segment.parse(file)
    assert length(parsed.blocks) == parsed.header.block_count

    rows =
      for i <- 0..(parsed.header.block_count - 1) do
        {:ok, frame} = Segment.frame(file, parsed, i)
        {:ok, events, _} = Block.decompress(frame)
        bloom = Enum.at(parsed.block_blooms, i)

        for e <- events, e.did != "" do
          assert Gloom.member?(bloom, e.did), "block #{i} bloom lacks #{e.did}"
          assert Gloom.member?(parsed.segment_bloom, e.did)
        end

        present =
          events
          |> Enum.flat_map(
            &Enum.reject([&1.collection, Event.sentinel(&1)], fn c -> c in [nil, ""] end)
          )
          |> Enum.uniq()
          |> Enum.map(&Enum.find_index(parsed.collections, fn c -> c == &1 end))
          |> Enum.sort()

        assert present == Enum.at(parsed.block_collections, i)
        events
      end
      |> List.flatten()

    assert length(rows) == parsed.header.event_count

    assert rows |> Enum.map(& &1.did) |> Enum.reject(&(&1 == "")) |> Enum.uniq() |> length() ==
             parsed.header.unique_did_count

    # a corrupted footer byte is caught by the checksum
    last = byte_size(file) - 1
    <<head::binary-size(^last), b>> = file
    assert {:error, _} = Segment.parse(<<head::binary, Bitwise.bxor(b, 1)>>)
  end

  test "names and gloom sizing" do
    assert Segment.filename(82) == "seg_000000002a.jss"
    assert Segment.parse_filename("seg_000000002a.jss") == {:ok, 82}
    assert Segment.parse_filename("seg_000000002A.jss") == :error
    assert Segment.parse_filename("seg_2a.jss") == :error

    f = Enum.reduce(1..1000, Gloom.new(1000, 0.001), &Gloom.add(&2, "did:plc:#{&1}"))
    assert Enum.all?(1..1000, &Gloom.member?(f, "did:plc:#{&1}"))
    false_positives = Enum.count(1001..11_000, &Gloom.member?(f, "did:plc:#{&1}"))
    assert false_positives < 50
    assert {:ok, back} = Gloom.unmarshal(Gloom.marshal(f))
    assert Gloom.marshal(back) == Gloom.marshal(f)
  end
end
