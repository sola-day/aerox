defmodule Aerox.ATProto.SpaceGoldenTest do
  @moduledoc "DESIGN §12.7: LtHash and commit vectors from the alpha primitives, before any endpoint."
  use Aerox.GoldenCase, async: true
  alias Aerox.ATProto.Crypto
  alias Aerox.ATProto.Space.{Commit, LtHash, Repo}

  test "LtHash: expansion, add/remove mod 2^16, digest, order independence" do
    g = json_golden!("space/lthash.json")
    assert LtHash.to_hex(LtHash.new()) == g["empty"]
    assert Base.encode16(LtHash.digest(LtHash.new()), case: :lower) == g["emptyDigest"]

    for %{"element" => e, "expansion" => x} <- g["expansions"] do
      assert LtHash.to_hex(LtHash.expand(e)) == x
    end

    Enum.reduce(g["steps"], LtHash.new(), fn %{
                                               "op" => op,
                                               "element" => e,
                                               "state" => s,
                                               "digest" => d
                                             },
                                             acc ->
      acc = if op == "add", do: LtHash.add(acc, e), else: LtHash.remove(acc, e)
      assert LtHash.to_hex(acc) == s
      assert Base.encode16(LtHash.digest(acc), case: :lower) == d
      acc
    end)

    els = Enum.map(g["expansions"], & &1["element"])
    forward = Enum.reduce(els, LtHash.new(), &LtHash.add(&2, &1))
    reverse = Enum.reduce(Enum.reverse(els), LtHash.new(), &LtHash.add(&2, &1))
    assert forward == reverse and LtHash.to_hex(forward) == g["orderIndependent"]["forward"]

    triple =
      Enum.reduce(1..3, LtHash.new(), fn _, acc -> LtHash.add(acc, g["tripleAdd"]["element"]) end)

    assert LtHash.to_hex(triple) == g["tripleAdd"]["state"]
  end

  test "commit: info encoding, HKDF key, MAC; signature over ikm" do
    g = json_golden!("space/commit.json")

    for v <- g["vectors"] do
      s = v["space"]

      ctx = %{
        space_did: s["spaceDid"],
        space_type: s["spaceType"],
        space_key: s["spaceKey"],
        user_did: s["userDid"],
        rev: s["rev"],
        scope: s["scope"]
      }

      hex = &Base.encode16(&1, case: :lower)
      ikm = Base.decode16!(v["ikm"], case: :lower)
      hash = Base.decode16!(v["hash"], case: :lower)
      assert hex.(Commit.info(ctx)) == v["info"]
      assert hex.(Commit.derive_key(ikm, Commit.info(ctx))) == v["derivedKey"]
      assert hex.(Commit.mac(ikm, hash, ctx)) == v["mac"]

      assert Commit.verify_mac(
               %{ikm: ikm, hash: hash, mac: Base.decode16!(v["mac"], case: :lower)},
               ctx
             )

      refute Commit.verify_mac(
               %{ikm: ikm, hash: hash, mac: Base.decode16!(v["mac"], case: :lower)},
               %{ctx | rev: "3mv4fihuqwc2z"}
             )
    end

    kp = Crypto.generate(:k256)

    ctx = %{
      space_did: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
      space_type: "com.atproto.simplespace",
      space_key: "k",
      user_did: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb",
      rev: "3mv4fihuqwc2h",
      scope: "records"
    }

    commit = Commit.create(LtHash.digest(LtHash.new()), ctx, kp)
    assert Commit.verify_mac(commit, ctx)
    assert Commit.verify_sig(commit, Crypto.did_key(kp))
    refute Commit.verify_sig(commit, Crypto.did_key(Crypto.generate(:k256)))
    assert Commit.from_lex(Commit.to_lex(commit)) == commit
  end

  test "repo: create/update/delete keep the set hash consistent; two-root CAR round-trips" do
    kp = Crypto.generate(:k256)

    ctx = %{
      space_did: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
      space_type: "com.atproto.simplespace",
      space_key: "k",
      user_did: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb",
      rev: "3mv4fihuqwc2h",
      scope: "records"
    }

    r1 = %{"$type" => "my.bulletin.post", "text" => "one"}
    r2 = %{"$type" => "my.bulletin.post", "text" => "two"}

    {:ok, [c1, c2], state} =
      Repo.format_commit(Repo.new(), [
        %{action: :create, collection: "my.bulletin.post", rkey: "a", record: r1},
        %{action: :create, collection: "my.bulletin.post", rkey: "b", record: r2}
      ])

    assert c1.cid == Repo.record_cid(r1) and c2.prev == nil

    assert {:error, {:record_already_exists, _, _}} =
             Repo.format_commit(state, [
               %{action: :create, collection: "my.bulletin.post", rkey: "a", record: r1}
             ])

    assert {:error, {:record_not_found, _, _}} =
             Repo.format_commit(state, [
               %{action: :delete, collection: "my.bulletin.post", rkey: "zzz", record: nil}
             ])

    {:ok, [u], state2} =
      Repo.format_commit(state, [
        %{
          action: :update,
          collection: "my.bulletin.post",
          rkey: "a",
          record: %{"$type" => "my.bulletin.post", "text" => "one!"}
        }
      ])

    assert u.prev == c1.cid

    {:ok, [d], state3} =
      Repo.format_commit(state2, [
        %{action: :delete, collection: "my.bulletin.post", rkey: "b", record: nil}
      ])

    assert d.prev == c2.cid and map_size(state3.records) == 1
    # the incremental hash equals a recomputation from the remaining records
    assert state3.set_hash == Repo.recompute(state3.records).set_hash

    commit = Commit.create(LtHash.digest(state3.set_hash), ctx, kp)
    car = Repo.export_car(state3, commit)
    assert {:ok, ^commit, back} = Repo.import_car(car)
    assert back.set_hash == state3.set_hash and Repo.index(back) == Repo.index(state3)
  end
end
