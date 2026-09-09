defmodule Aerox.ATProto.RepoTest do
  @moduledoc """
  L2/L3: commit production round-trips through the CAR reader and verifier;
  the four real firehose commits from indigo's testdata pass inductive
  verification (VERIFICATION §12 Kernel: "a real CAR loads and its root
  recomputes").
  """
  use Aerox.GoldenCase, async: true
  alias Aerox.ATProto.{Blockstore, Bytes, CAR, CID, Crypto, Data, Frame, MST, Repo, TID}
  alias Aerox.ATProto.Blockstore.Memory

  @did "did:plc:ewvi7nxzyoun6zhxrhs64oiz"

  defp tid(n), do: TID.from_time(1_700_000_000_000_000 + n * 1_000_000, 7)

  defp post(text),
    do: %{
      "$type" => "app.bsky.feed.post",
      "text" => text,
      "createdAt" => "2026-09-09T00:00:00.000Z"
    }

  test "init commit, writes, export, verify: the root recomputes and records come back" do
    kp = Crypto.generate(:k256)
    bs = Memory.new()

    {:ok, c0} = Repo.format_init_commit(bs, @did, kp, [], tid(0))
    {:ok, bs} = Blockstore.put_many(bs, Map.to_list(c0.new_blocks))
    assert c0.ops == []
    assert Repo.verify_commit_sig(c0.commit, Crypto.did_key(kp))
    refute Repo.verify_commit_sig(c0.commit, Crypto.did_key(Crypto.generate(:k256)))

    {:ok, repo} = Repo.load(bs, c0.cid)

    writes =
      for i <- 1..25,
          do:
            {:create, "app.bsky.feed.post",
             "3jqfcqzm3f#{String.pad_leading(Integer.to_string(i, 32), 3, "2")}",
             post("post #{i}")}

    {:ok, c1} = Repo.format_commit(bs, repo, writes, kp, tid(1))
    assert length(c1.ops) == 25
    assert Enum.all?(c1.ops, &(&1.action == :create and &1.prev == nil))
    assert c1.prev == c0.cid and c1.since == c0.rev and c1.prev_data == c0.data
    assert MapSet.member?(c1.removed_cids, c0.cid)
    {:ok, bs} = Blockstore.put_many(bs, Map.to_list(c1.new_blocks))

    {:ok, repo} = Repo.load(bs, c1.cid)
    [%{path: path} | _] = c1.ops
    {:ok, coll, rkey} = Repo.parse_data_key(path)
    assert {:ok, _cid, %{"text" => "post 1"}} = Repo.get_record(bs, repo, coll, rkey)

    # update one, delete one, re-create one in a single commit
    {:ok, c2} =
      Repo.format_commit(
        bs,
        repo,
        [
          {:update, coll, rkey, post("edited")},
          {:delete, coll, elem(Repo.parse_data_key(Enum.at(c1.ops, 1).path), 2)}
        ],
        kp,
        tid(2)
      )

    assert [%{action: :update, prev: %CID{}}, %{action: :delete, cid: nil, prev: %CID{}}] = c2.ops
    {:ok, bs} = Blockstore.put_many(bs, Map.to_list(c2.new_blocks))

    # rev must move forward
    {:ok, repo2} = Repo.load(bs, c2.cid)
    assert {:error, {:rev_not_newer, _, _}} = Repo.format_commit(bs, repo2, [], kp, tid(2))

    assert {:error, {:record_not_found, _}} =
             Repo.format_commit(bs, repo2, [{:delete, coll, "nope"}], kp, tid(3))

    # export and verify from scratch: the whole point of DESIGN §3.5 step 1
    {:ok, car} = Repo.export_car(bs, c2.cid)
    assert {:ok, verified} = Repo.verify_repo_car(car, did: @did, signing_key: Crypto.did_key(kp))
    assert length(verified.records) == 24
    assert Enum.all?(verified.records, &(&1.action == :create))
    assert {:error, {:invalid_repo_did, _}} = Repo.verify_repo_car(car, did: "did:plc:other")

    assert {:error, :invalid_signature} =
             Repo.verify_repo_car(car, signing_key: Crypto.did_key(Crypto.generate(:p256)))

    # the CAR from the memory store equals a CAR rebuilt from the verified store
    {:ok, ^car} = Repo.export_car(verified.blockstore, c2.cid)

    # record proof: commit + path + record, verifiable on its own
    {:ok, proof} = Repo.record_proof_blocks(bs, c2.cid, coll, rkey)
    {:ok, pr} = Repo.load(Memory.new(proof), c2.cid)
    assert {:ok, _, %{"text" => "edited"}} = Repo.get_record(Memory.new(proof), pr, coll, rkey)
  end

  test "a formatted commit verifies inductively as a firehose event, including a P-256 signer" do
    for curve <- [:k256, :p256] do
      kp = Crypto.generate(curve)
      bs = Memory.new()

      {:ok, c0} =
        Repo.format_init_commit(
          bs,
          @did,
          kp,
          [{:create, "app.bsky.feed.post", "a", post("a")}],
          tid(0)
        )

      {:ok, bs} = Blockstore.put_many(bs, Map.to_list(c0.new_blocks))
      {:ok, repo} = Repo.load(bs, c0.cid)

      {:ok, c1} =
        Repo.format_commit(
          bs,
          repo,
          [{:create, "app.bsky.feed.post", "b", post("b")}, {:delete, "app.bsky.feed.post", "a"}],
          kp,
          tid(1)
        )

      event = %{
        "repo" => @did,
        "rev" => c1.rev,
        "since" => c1.since,
        "commit" => c1.cid,
        "prevData" => c1.prev_data,
        "blocks" =>
          Bytes.new(CAR.encode(c1.cid, Map.to_list(Map.merge(c1.new_blocks, c1.relevant_blocks)))),
        "ops" =>
          Enum.map(
            c1.ops,
            &%{
              "action" => Atom.to_string(&1.action),
              "path" => &1.path,
              "cid" => &1.cid,
              "prev" => &1.prev
            }
          )
      }

      assert {:ok, %{inverted: true}} =
               Repo.verify_commit_message(event, signing_key: Crypto.did_key(kp))

      assert {:error, :prev_data_mismatch} =
               Repo.verify_commit_message(%{event | "prevData" => c1.data})

      assert {:error, :invalid_signature} =
               Repo.verify_commit_message(event,
                 signing_key: Crypto.did_key(Crypto.generate(curve))
               )

      assert {:error, :rev_mismatch} = Repo.verify_commit_message(%{event | "rev" => tid(5)})
    end
  end

  for seq <- ["4621317030", "4621317332", "4621332152", "4623075231"] do
    test "real firehose commit #{seq} verifies inductively" do
      event = Data.from_json!(json_golden!("firehose/firehose_commit_#{unquote(seq)}.json"))
      # these 2025 captures predate prevData, so the tree inversion is skipped, as indigo does
      assert {:ok, %{inverted: inverted, repo: repo, ops: ops}} =
               Repo.verify_commit_message(event)

      assert inverted == Map.has_key?(event, "prevData")
      assert repo.commit["did"] == event["repo"]
      assert length(ops) == length(event["ops"])
      # the partial tree loaded from the event verifies structurally as far as it goes
      {:ok, _, bs} = CAR.to_blockstore(event["blocks"].data)
      assert :ok = MST.verify_structure(bs, repo.data)
    end
  end

  test "frames round-trip and reject malformed input" do
    body = %{"seq" => 1, "did" => @did, "time" => "2026-09-09T00:00:00.000Z", "active" => true}

    bytes =
      Frame.encode(
        Frame.message(
          Map.put(body, "$type", "com.atproto.sync.subscribeRepos#account"),
          "com.atproto.sync.subscribeRepos"
        )
      )

    assert {:ok, {:message, "#account", ^body}} = Frame.decode(bytes)

    assert {:ok, {:error, "FutureCursor", "Cursor in the future."}} =
             Frame.decode(Frame.encode({:error, "FutureCursor", "Cursor in the future."}))

    assert {:error, :missing_frame_body} =
             Frame.decode(Aerox.ATProto.DagCBOR.encode(%{"op" => 1}))

    assert {:error, :too_many_items} = Frame.decode(bytes <> <<0x01>>)
  end
end

defmodule Aerox.ATProto.RealCarTest do
  @moduledoc "VERIFICATION §12 Kernel exit: a real CAR exported from the reference PDS loads, its root recomputes, its signature verifies."
  use Aerox.GoldenCase, async: true
  alias Aerox.ATProto.{CAR, Identity, MST, Repo}

  @did "did:plc:mdzwr2hlx4w3tc5mbxm3mqbq"

  test "the reference-PDS CAR verifies end to end and re-exports to the same block set" do
    car = read_golden!("car/#{@did |> String.replace(":", "-")}.car")
    doc = json_golden!("car/#{@did |> String.replace(":", "-")}.did.json")
    assert Identity.did(doc) == @did
    {:ok, did_key} = Identity.signing_did_key(doc)

    assert {:ok, %{commit: commit, records: records, blockstore: bs}} =
             Repo.verify_repo_car(car, did: @did, signing_key: did_key)

    assert commit["did"] == @did and commit["version"] == 3
    assert records != []
    assert Enum.all?(records, &(&1.action == :create))

    {:ok, root, blocks} = CAR.decode_with_root(car)
    {:ok, repo} = Repo.load(bs, root)
    assert :ok = MST.verify_structure(bs, repo.data)

    assert {:ok, recomputed} = MST.recompute_root(bs, repo.data)
    assert recomputed == commit["data"]

    # every record in the tree is present and decodes; the profile is there
    {:ok, leaves} = MST.leaves(bs, repo.data)
    assert length(leaves) == length(records)
    assert Enum.any?(leaves, fn {k, _} -> k == "app.bsky.actor.profile/self" end)

    assert {:ok, _, %{"$type" => "app.bsky.actor.profile"}} =
             Repo.get_record(bs, repo, "app.bsky.actor.profile", "self")

    # re-export: same commit, same block set (order may differ)
    {:ok, exported} = Repo.export_car(bs, root)
    {:ok, ^root, blocks2} = CAR.decode_with_root(exported)
    assert MapSet.new(blocks2) == MapSet.new(blocks)
  end
end
