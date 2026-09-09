defmodule Aerox.ATProto.MSTGoldenTest do
  @moduledoc """
  L2 (VERIFICATION §3.1): the MST interop roots from upstream's mst.test.ts,
  the commit-proof fixtures (root before/after applying adds and deletes),
  the key rules, and indigo's example key set.
  """
  use Aerox.GoldenCase, async: true
  alias Aerox.ATProto.{Blockstore, CID, MST}
  alias Aerox.ATProto.Blockstore.Memory

  @known json_golden!("mst/known-maps.json")
  @leaf CID.parse!(@known["leafValue"])

  defp build(keys, bs) do
    Enum.reduce(keys, MST.empty(), fn key, tree ->
      {:ok, tree} = MST.add(bs, tree, key, @leaf)
      tree
    end)
  end

  defp root_string(bs, tree) do
    {:ok, cid, _} = MST.root(bs, tree)
    CID.to_string(cid)
  end

  for %{"name" => name} = c <- @known["cases"] do
    test "known map #{name}" do
      c = unquote(Macro.escape(c))
      bs = Memory.new()
      tree = build(c["keys"], bs)
      assert root_string(bs, tree) == c["root"]
      assert {:ok, layer} = MST.layer(bs, tree)
      assert layer == c["layer"]
      assert {:ok, n} = MST.leaf_count(bs, tree)
      assert n == length(c["keys"])
    end
  end

  for %{"name" => name} = seq <- @known["sequences"] do
    test "edge case: #{name}" do
      bs = Memory.new()

      Enum.reduce(unquote(Macro.escape(seq))["steps"], MST.empty(), fn step, tree ->
        tree =
          Enum.reduce(step["add"] || [], tree, fn k, t ->
            {:ok, t} = MST.add(bs, t, k, @leaf)
            t
          end)

        tree =
          Enum.reduce(step["del"] || [], tree, fn k, t ->
            {:ok, t} = MST.delete(bs, t, k)
            t
          end)

        assert root_string(bs, tree) == step["root"]
        assert {:ok, step["leaves"]} == MST.leaf_count(bs, tree)
        assert {:ok, step["layer"]} == MST.layer(bs, tree)
        tree
      end)
    end
  end

  test "key rules" do
    for k <- @known["allowedKeys"], do: assert(MST.valid_key?(k), k)
    for k <- @known["rejectedKeys"], do: refute(MST.valid_key?(k), k)
    refute MST.valid_key?("coll/" <> String.duplicate("a", @known["maxKeyLength"]))
    assert MST.valid_key?("coll/" <> String.duplicate("a", @known["maxKeyLength"] - 5))
  end

  test "known-map roots are insertion-order independent and survive a store round trip" do
    keys = Enum.find(@known["cases"], &(&1["name"] == "simple"))["keys"]
    expected = Enum.find(@known["cases"], &(&1["name"] == "simple"))["root"]

    for perm <- [Enum.reverse(keys), Enum.shuffle(keys), Enum.sort(keys, :desc)] do
      bs = Memory.new()
      tree = build(perm, bs)
      assert root_string(bs, tree) == expected
      {:ok, root, blocks, _} = MST.unstored_blocks(bs, tree)
      {:ok, bs} = Blockstore.put_many(bs, blocks)
      loaded = MST.load(root)
      assert {:ok, leaves} = MST.leaves(bs, loaded)
      assert Enum.map(leaves, &elem(&1, 0)) == Enum.sort(keys)
      assert :ok = MST.verify_structure(bs, loaded)
      assert {:ok, @leaf} = MST.get(bs, loaded, hd(keys))
      assert {:ok, nil} = MST.get(bs, loaded, "com.example.record/nope")
    end
  end

  describe "commit-proof fixtures" do
    for {%{"comment" => comment} = fixture, i} <-
          Enum.with_index(json_golden!("mst/commit-proof-fixtures.json")) do
      test "#{i}: #{comment}" do
        f = unquote(Macro.escape(fixture))
        leaf = CID.parse!(f["leafValue"])
        bs = Memory.new()

        before =
          Enum.reduce(f["keys"], MST.empty(), fn k, t ->
            {:ok, t} = MST.add(bs, t, k, leaf)
            t
          end)

        {:ok, before_root, blocks, before} = MST.unstored_blocks(bs, before)
        assert CID.to_string(before_root) == f["rootBeforeCommit"]
        {:ok, bs} = Blockstore.put_many(bs, blocks)

        after_ =
          Enum.reduce(f["adds"], before, fn k, t ->
            {:ok, t} = MST.add(bs, t, k, leaf)
            t
          end)

        after_ =
          Enum.reduce(f["dels"], after_, fn k, t ->
            {:ok, t} = MST.delete(bs, t, k)
            t
          end)

        {:ok, after_root, new_blocks, after_} = MST.unstored_blocks(bs, after_)
        assert CID.to_string(after_root) == f["rootAfterCommit"]

        assert {:ok, diff} = MST.diff(bs, before, after_)
        assert Map.keys(diff.adds) |> Enum.sort() == Enum.sort(f["adds"])
        assert Map.keys(diff.deletes) |> Enum.sort() == Enum.sort(f["dels"])
        {:ok, bs} = Blockstore.put_many(bs, new_blocks)

        # Upstream's inductive test: the union of covering proofs for the touched
        # keys contains every block the fixture names, and a tree loaded from
        # ONLY those blocks can invert the ops in any order back to rootBefore.
        proof =
          Enum.reduce(f["adds"] ++ f["dels"], %{}, fn k, acc ->
            {:ok, p} = MST.covering_proof(bs, after_, k)
            Map.merge(acc, p)
          end)

        for c <- f["blocksInProof"],
            do: assert(Map.has_key?(proof, CID.parse!(c)), "proof lacks #{c}")

        proof_bs = Memory.new(proof)
        inverts = Enum.map(f["adds"], &{:del, &1}) ++ Enum.map(f["dels"], &{:add, &1})

        for order <- permutations(inverts) do
          tree =
            Enum.reduce(order, MST.load(after_root), fn
              {:del, k}, t ->
                {:ok, t} = MST.delete(proof_bs, t, k)
                t

              {:add, k}, t ->
                {:ok, t} = MST.add(proof_bs, t, k, leaf)
                t
            end)

          assert root_string(proof_bs, tree) == f["rootBeforeCommit"], "order #{inspect(order)}"
        end

        assert :ok = MST.verify_structure(bs, after_)
      end
    end
  end

  defp permutations([]), do: [[]]
  defp permutations(list), do: for(x <- list, rest <- permutations(list -- [x]), do: [x | rest])

  test "indigo example keys build a tree that round-trips through its blocks" do
    keys = lines("mst/example_keys.txt")
    bs = Memory.new()
    tree = build(keys, bs)
    {:ok, root, blocks, _} = MST.unstored_blocks(bs, tree)
    {:ok, bs} = Blockstore.put_many(bs, blocks)
    assert {:ok, leaves} = MST.leaves(bs, MST.load(root))
    assert length(leaves) == length(Enum.uniq(keys))
    assert :ok = MST.verify_structure(bs, MST.load(root))
    assert {:ok, some} = MST.list_with_prefix(bs, MST.load(root), "app.bsky.feed.post/")
    assert Enum.all?(some, fn {k, _} -> String.starts_with?(k, "app.bsky.feed.post/") end)
    assert {:ok, [_ | _] = page} = MST.list(bs, MST.load(root), count: 3)
    assert length(page) == 3
    [{first, _} | _] = page
    assert {:ok, next} = MST.list(bs, MST.load(root), after: first, count: 2)
    assert Enum.all?(next, fn {k, _} -> k > first end)
  end
end
