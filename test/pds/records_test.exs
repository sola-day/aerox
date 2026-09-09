defmodule Aerox.PDS.RecordsTest do
  @moduledoc """
  VERIFICATION §5 PDS: the write path produces commits whose CAR round-trips
  through the kernel, repo_root advances, the sequencer emits exactly one
  event per commit with the right ops and prevData; N concurrent writes to
  one DID serialise; swaps; unknown-lexicon admission; backlink conflicts.
  """
  use Aerox.DataCase, async: false, repos: [Aerox.PDS.Repo]
  alias Aerox.ATProto.{Bytes, CAR, CID, Crypto, Data, Frame}
  alias Aerox.ATProto.Repo, as: KRepo
  alias Aerox.PDS.{Records, Sequencer}
  alias Aerox.PDS.Records.Prepare
  alias Aerox.PDS.Schema.{Actor, RepoRoot}

  @moduletag :service

  setup do
    kp = Crypto.generate(:k256)

    did =
      "did:plc:" <> (:crypto.strong_rand_bytes(15) |> Base.encode32(case: :lower, padding: false))

    Aerox.PDS.Repo.insert!(%Actor{
      did: did,
      handle: "alice-#{System.unique_integer([:positive])}.test",
      signing_key: kp.private,
      created_at: DateTime.utc_now()
    })

    {:ok, commit} = Records.create_repo(did, kp)
    Phoenix.PubSub.subscribe(Aerox.PubSub, Sequencer.topic())
    {:ok, did: did, kp: kp, init: commit}
  end

  # A deterministic TID per index: app.bsky.feed.post keys must be TIDs now
  # that its lexicon is vendored (record key rule "tid").
  defp tid(i), do: Aerox.ATProto.TID.from_time(1_700_000_000_000_000 + i * 1_000_000, 7)

  defp post(text),
    do: %{
      "$type" => "app.bsky.feed.post",
      "text" => text,
      "createdAt" => "2026-09-09T00:00:00.000Z"
    }

  test "create, update, delete: commits verify, root advances, one event per commit", %{
    did: did,
    kp: kp,
    init: init
  } do
    {:ok, w1} = Prepare.create(did, "app.bsky.feed.post", post("hello"), rkey: "3jqfcqzm3fo2j")
    assert w1.validation_status == :valid
    assert {:ok, c1} = Records.process_writes(did, [w1])
    assert c1.since == init.rev and c1.prev_data == init.data
    assert [%{action: :create, path: "app.bsky.feed.post/3jqfcqzm3fo2j", prev: nil}] = c1.ops
    assert Records.root(did).cid == c1.cid
    assert_receive {:firehose, [row]}, 2_000
    assert row.did == did and row.event_type == "append" and row.seq == c1.seq

    # the broadcast event verifies inductively with the account's key
    {"#commit", body} = Aerox.PDS.Sequencer.Events.to_frame(row)

    assert {:ok, %{inverted: true}} =
             KRepo.verify_commit_message(body, signing_key: Crypto.did_key(kp))

    assert body["since"] == init.rev and body["prevData"] == init.data

    assert {:ok, %{value: %{"text" => "hello"}, cid: cid1}} =
             Records.get_record(did, "app.bsky.feed.post", "3jqfcqzm3fo2j")

    {:ok, w2} = Prepare.update(did, "app.bsky.feed.post", "3jqfcqzm3fo2j", post("edited"))
    assert {:ok, c2} = Records.process_writes(did, [w2])
    assert [%{action: :update, prev: prev}] = c2.ops
    assert CID.to_string(prev) == cid1
    assert_receive {:firehose, [_]}, 2_000

    {:ok, w3} = Prepare.delete(did, "app.bsky.feed.post", "3jqfcqzm3fo2j")
    assert {:ok, c3} = Records.process_writes(did, [w3])
    assert [%{action: :delete, cid: nil, prev: %CID{}}] = c3.ops
    assert {:error, :not_found} = Records.get_record(did, "app.bsky.feed.post", "3jqfcqzm3fo2j")
    assert Records.record_count(did) == 0

    # the whole repo exports as a CAR that verifies from scratch
    bs = Aerox.PDS.Blockstore.new(did)
    {:ok, car} = KRepo.export_car(bs, c3.cid)

    assert {:ok, %{records: []}} =
             KRepo.verify_repo_car(car, did: did, signing_key: Crypto.did_key(kp))

    # three commits, three events, strictly increasing seqs
    assert c1.seq < c2.seq and c2.seq < c3.seq
    assert Sequencer.current() >= c3.seq
  end

  test "swap semantics", %{did: did} do
    {:ok, w} = Prepare.create(did, "app.bsky.feed.post", post("a"), rkey: tid(1))
    {:ok, c1} = Records.process_writes(did, [w])
    {:ok, w2} = Prepare.create(did, "app.bsky.feed.post", post("b"), rkey: tid(2))

    assert {:error, %Records.Error{kind: :invalid_swap}} =
             Records.process_writes(did, [w2], swap_commit: CID.for_cbor("wrong"))

    assert {:ok, _} = Records.process_writes(did, [w2], swap_commit: c1.cid)

    {:ok, wu} =
      Prepare.update(did, "app.bsky.feed.post", tid(1), post("a2"),
        swap_cid: CID.for_cbor("wrong")
      )

    assert {:error, %Records.Error{kind: :invalid_swap}} = Records.process_writes(did, [wu])
    {:ok, %{cid: current}} = Records.get_record(did, "app.bsky.feed.post", tid(1))

    {:ok, wu2} =
      Prepare.update(did, "app.bsky.feed.post", tid(1), post("a2"), swap_cid: CID.parse!(current))

    assert {:ok, _} = Records.process_writes(did, [wu2])

    {:ok, wc} =
      Prepare.create(did, "app.bsky.feed.post", post("c"),
        rkey: tid(3),
        swap_cid: CID.parse!(current)
      )

    assert {:error, %Records.Error{kind: :invalid_swap}} = Records.process_writes(did, [wc])
  end

  test "N concurrent writes to one DID produce N sequential commits; different DIDs interleave",
       %{did: did, kp: kp} do
    kp2 = Crypto.generate(:k256)

    did2 =
      "did:plc:" <> (:crypto.strong_rand_bytes(15) |> Base.encode32(case: :lower, padding: false))

    Aerox.PDS.Repo.insert!(%Actor{
      did: did2,
      handle: "bob-#{System.unique_integer([:positive])}.test",
      signing_key: kp2.private,
      created_at: DateTime.utc_now()
    })

    {:ok, _} = Records.create_repo(did2, kp2)

    results =
      1..12
      |> Task.async_stream(
        fn i ->
          Ecto.Adapters.SQL.Sandbox.allow(Aerox.PDS.Repo, self(), self())
          target = if rem(i, 2) == 0, do: did, else: did2
          {:ok, w} = Prepare.create(target, "app.bsky.feed.post", post("p#{i}"), rkey: tid(i))
          {target, Records.process_writes(target, [w])}
        end,
        max_concurrency: 12,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &match?({_, {:ok, _}}, &1))

    for d <- [did, did2] do
      commits = for {^d, {:ok, c}} <- results, do: c
      revs = Enum.map(commits, & &1.rev) |> Enum.sort()
      # every commit's `since` is another commit's rev (or the init): a chain, no forks
      sinces = Enum.map(commits, & &1.since) |> Enum.sort()
      assert length(Enum.uniq(revs)) == 6 and length(Enum.uniq(sinces)) == 6
      assert Records.record_count(d) == 6

      assert {:ok, leaves} =
               Aerox.ATProto.MST.leaves(
                 Aerox.PDS.Blockstore.new(d),
                 Aerox.ATProto.MST.load(
                   Records.root(d)
                   |> then(fn r ->
                     {:ok, repo} = KRepo.load(Aerox.PDS.Blockstore.new(d), r.cid)
                     repo.commit["data"]
                   end)
                 )
               )

      assert length(leaves) == 6
    end

    _ = kp
  end

  test "three-state validation (DESIGN §6.3) and prepare errors", %{did: did} do
    schema = %{"$type" => "com.atproto.lexicon.schema", "lexicon" => 1}

    assert {:ok, %{validation_status: :valid}} =
             Prepare.create(did, "com.atproto.lexicon.schema", schema, rkey: "com.example.thing")

    assert {:error, {:invalid_record, "Invalid record key for" <> _}} =
             Prepare.create(did, "com.atproto.lexicon.schema", schema, rkey: "not-an-nsid")

    assert {:error, {:invalid_record, "Invalid com.atproto.lexicon.schema record" <> _}} =
             Prepare.create(
               did,
               "com.atproto.lexicon.schema",
               %{"$type" => "com.atproto.lexicon.schema"},
               rkey: "com.example.thing"
             )

    assert {:ok, %{validation_status: :valid}} =
             Prepare.create(did, "app.bsky.feed.post", post("x"))

    assert {:ok, %{validation_status: :unknown}} =
             Prepare.create(did, "com.example.unknown", %{"$type" => "com.example.unknown"})

    assert {:error, {:invalid_record, "Unknown lexicon type" <> _}} =
             Prepare.create(did, "com.example.unknown", %{"$type" => "com.example.unknown"},
               validate: true
             )

    assert {:ok, %{validation_status: :skipped}} =
             Prepare.create(did, "app.bsky.feed.post", post("x"), validate: false)

    assert {:error, {:invalid_record, "Invalid $type" <> _}} =
             Prepare.create(did, "app.bsky.feed.post", %{"$type" => "app.bsky.feed.like"})

    assert {:error, {:invalid_record_key, _}} =
             Prepare.create(did, "app.bsky.feed.post", post("x"), rkey: "bad key")

    assert {:error, {:invalid_record, "Legacy blobs" <> _}} =
             Prepare.create(
               did,
               "app.bsky.feed.post",
               Map.put(post("x"), "embed", %{
                 "cid" => "bafkreiccldh766hwcnuxnf2wh6jgzepf2nlu2lvcllt63eww5p6chi4ity",
                 "mimeType" => "image/png"
               })
             )

    # a minted rkey is a TID
    {:ok, w} = Prepare.create(did, "app.bsky.feed.post", post("x"))
    assert Aerox.ATProto.Syntax.valid_tid?(w.rkey)
  end

  test "backlinks and conflicts; blob references follow the record", %{did: did} do
    follow = %{
      "$type" => "app.bsky.graph.follow",
      "subject" => "did:plc:ewvi7nxzyoun6zhxrhs64oiz",
      "createdAt" => "2026-09-09T00:00:00.000Z"
    }

    {:ok, w} = Prepare.create(did, "app.bsky.graph.follow", follow, rkey: tid(11))
    {:ok, _} = Records.process_writes(did, [w])

    assert [_] =
             Records.backlink_conflicts(
               did,
               "at://#{did}/app.bsky.graph.follow/f2",
               "app.bsky.graph.follow",
               follow
             )

    assert [] =
             Records.backlink_conflicts(did, "x", "app.bsky.feed.like", %{
               "$type" => "app.bsky.feed.like",
               "subject" => %{"uri" => "at://did:plc:abc/app.bsky.feed.post/1"}
             })

    cid = CID.for_raw("image bytes")

    Aerox.PDS.Repo.insert!(%Aerox.PDS.Schema.Blob{
      did: did,
      cid: CID.to_string(cid),
      mime_type: "image/png",
      size: 11,
      created_at: DateTime.utc_now()
    })

    embed = %{
      "$type" => "app.bsky.embed.images",
      "images" => [
        %{
          "image" => %{
            "$type" => "blob",
            "ref" => %{"$link" => CID.to_string(cid)},
            "mimeType" => "image/png",
            "size" => 11
          },
          "alt" => ""
        }
      ]
    }

    {:ok, w} =
      Prepare.create(did, "app.bsky.feed.post", Map.put(post("pic"), "embed", embed),
        rkey: tid(9)
      )

    assert [%{"ref" => ^cid}] = w.blobs
    {:ok, _} = Records.process_writes(did, [w])
    assert [%{blob_cid: bc}] = Aerox.PDS.Repo.all(Aerox.PDS.Schema.RecordBlob)
    assert bc == CID.to_string(cid)

    {:ok, d} = Prepare.delete(did, "app.bsky.feed.post", tid(9))
    {:ok, _} = Records.process_writes(did, [d])
    assert [] = Aerox.PDS.Repo.all(Aerox.PDS.Schema.RecordBlob)
    assert [] = Aerox.PDS.Repo.all(Aerox.PDS.Schema.Blob)
  end

  test "list and get", %{did: did} do
    for i <- 1..5 do
      {:ok, w} = Prepare.create(did, "app.bsky.feed.post", post("p#{i}"), rkey: tid(i))
      {:ok, _} = Records.process_writes(did, [w])
    end

    assert [tid(5), tid(4)] ==
             Records.list_records(did, "app.bsky.feed.post", limit: 2) |> Enum.map(& &1.rkey)

    assert [tid(3), tid(2)] ==
             Records.list_records(did, "app.bsky.feed.post", limit: 2, cursor: tid(4))
             |> Enum.map(& &1.rkey)

    assert [tid(1), tid(2)] ==
             Records.list_records(did, "app.bsky.feed.post", limit: 2, reverse: true)
             |> Enum.map(& &1.rkey)

    assert ["app.bsky.feed.post"] = Records.list_collections(did)

    assert {:ok, %{value: %{"text" => "p3"}}} =
             Records.get_record(did, "app.bsky.feed.post", tid(3))

    :ok = Records.update_record_takedown(did, "at://#{did}/app.bsky.feed.post/#{tid(3)}", "mod-1")
    assert {:error, :not_found} = Records.get_record(did, "app.bsky.feed.post", tid(3))

    assert {:ok, _} =
             Records.get_record(did, "app.bsky.feed.post", tid(3), include_taken_down: true)
  end

  test "sequencer: batches coalesce, seqs are gap-free, last_seq survives a restart", %{did: did} do
    rows = for i <- 1..50, do: Aerox.PDS.Sequencer.Events.identity(did, "h#{i}.test")

    tasks =
      for chunk <- Enum.chunk_every(rows, 5),
          do:
            Task.async(fn ->
              Ecto.Adapters.SQL.Sandbox.allow(Aerox.PDS.Repo, self(), self())
              Sequencer.sequence(chunk)
            end)

    seqs = tasks |> Enum.map(&Task.await/1) |> Enum.flat_map(fn {:ok, s} -> s end) |> Enum.sort()
    assert length(seqs) == 50
    assert seqs == Enum.to_list(hd(seqs)..List.last(seqs))
    assert Sequencer.current() == List.last(seqs)
    assert [%{seq: s}] = Sequencer.range(List.last(seqs) - 1, 10) |> Enum.take(1)
    assert s == List.last(seqs)
    _ = Bytes
    _ = Data
    _ = Frame
    _ = CAR
    _ = RepoRoot
  end
end
