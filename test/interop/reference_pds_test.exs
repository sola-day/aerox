defmodule Aerox.Interop.ReferencePdsTest do
  @moduledoc """
  DESIGN §13.2 / VERIFICATION §8 against a real reference-PDS data directory
  (`test/golden/interop/ref-pds-0.4/`, a copy of the dev stack's ref-pds
  container: one account, a dev-only key and password hash).

  Reference dir → bundle → PG: the MST root recomputed from `repo.car` equals
  the source `repo_root.cid`'s commit data, counts match the snapshot's own
  numbers, `max(seq)` carries over, and `refREDACTED-peer-account-password-rotated-2026-09-16` logs in
  through our scrypt verifier. Then PG → bundle → reference dir with the 0.4
  Kysely rows, read back by the same adapter.

  Tagged `:tool` (needs exqlite; excluded by default):
  `mix test --include tool test/interop/reference_pds_test.exs`.
  """
  use Aerox.DataCase, async: false, repos: [Aerox.PDS.Repo]
  alias Aerox.ATProto.{CAR, CID, MST}
  alias Aerox.ATProto.Blockstore.Memory
  alias Aerox.ATProto.Repo, as: KRepo
  alias Aerox.Interop.{Bundle, Verify}
  alias Aerox.Interop.Bundle.Postgres
  alias Aerox.Interop.ReferencePds
  alias Aerox.Interop.ReferencePds.Sqlite
  alias Aerox.PDS.{Accounts, Repo}
  alias Aerox.PDS.Schema.{Record, RepoBlock, RepoRoot, RepoSeq}

  @moduletag :tool
  @moduletag :tmp_dir

  @fixture Path.expand("../golden/interop/ref-pds-0.4", __DIR__)
  @did "did:plc:j34mp52kqeqheoencw7lqpyy"
  @handle "refalice.ref-pds.aerox.sola.town"
  @password "refREDACTED-peer-account-password-rotated-2026-09-16"

  # the snapshot's own numbers (DESIGN §13.1 lesson 3), read straight from SQLite
  defp baseline do
    {:ok, acc} = Sqlite.open(Path.join(@fixture, "account.sqlite"))

    [%{"cid" => root_cid, "rev" => rev}] =
      Sqlite.query(acc, "SELECT cid, rev FROM repo_root WHERE did = ?", [@did])

    Sqlite.close(acc)
    {:ok, seq} = Sqlite.open(Path.join(@fixture, "sequencer.sqlite"))

    [%{"n" => seq_count, "max" => max_seq}] =
      Sqlite.query(seq, "SELECT count(*) AS n, max(seq) AS max FROM repo_seq WHERE did = ?", [
        @did
      ])

    [%{"event" => last_event}] =
      Sqlite.query(seq, "SELECT event FROM repo_seq WHERE did = ? ORDER BY seq DESC LIMIT 1", [
        @did
      ])

    Sqlite.close(seq)
    {:ok, store} = Sqlite.open(Path.join(ReferencePds.actor_dir(@fixture, @did), "store.sqlite"))
    [%{"n" => records}] = Sqlite.query(store, "SELECT count(*) AS n FROM record")
    [%{"n" => blocks}] = Sqlite.query(store, "SELECT count(*) AS n FROM repo_block")
    Sqlite.close(store)

    %{
      root_cid: root_cid,
      rev: rev,
      seq_count: seq_count,
      max_seq: max_seq,
      last_event: last_event,
      records: records,
      blocks: blocks
    }
  end

  test "reference dir → bundle → PG: MST root, counts, seq, and scrypt login", %{tmp_dir: dir} do
    base = baseline()
    assert base.records == 4 and base.blocks == 6 and base.seq_count == 8

    assert [%{did: @did, handle: @handle}] = ReferencePds.list_accounts(@fixture)
    out = Path.join(dir, "bundle")

    assert {:ok, manifest} =
             ReferencePds.export(@fixture, @did, out,
               takeover: true,
               host: "ref-pds.aerox.sola.town",
               pds_version: "0.4",
               recipients: [{:passphrase, "drill"}]
             )

    assert manifest["counts"] == %{
             "records" => 4,
             "blocks" => 6,
             "blobs" => 0,
             "quarantine" => 0,
             "seq_events" => 8
           }

    assert manifest["source"] == %{
             "impl" => "reference-pds",
             "version" => "0.4",
             "host" => "ref-pds.aerox.sola.town"
           }

    assert {:ok, bundle} = Bundle.read(out, secret: {:passphrase, "drill"})
    pre = Verify.bundle(bundle, takeover: true)
    assert pre.ok?, inspect(pre.checks)

    # the CAR's root is the source repo_root.cid and its MST recomputes from the verbatim blocks
    {:ok, car} = Bundle.read_file(bundle, "repo.car")
    {:ok, root, blocks} = CAR.decode_with_root(car)
    assert CID.to_string(root) == base.root_cid
    bs = Memory.new(blocks)
    {:ok, repo} = KRepo.load(bs, root)
    assert repo.commit["rev"] == base.rev
    assert {:ok, data_cid} = MST.recompute_root(bs, MST.load(repo.commit["data"]))
    assert data_cid == repo.commit["data"]

    # account.json carries upstream's scrypt hash verbatim
    {:ok, account} = Bundle.read_file(bundle, "account.json")
    account = Jason.decode!(account)
    assert account["email"] == "refalice@example.invalid"
    assert Aerox.Auth.Scrypt.verify(@password, account["password_scrypt"])

    # a takeover needs the target's sequencer to be behind the source (DESIGN §13.2): the
    # shared test database has rows from other tests, so clear the range inside the sandbox
    Repo.delete_all(from(s in RepoSeq, where: s.seq <= ^base.max_seq))
    assert {:ok, report} = Postgres.import(bundle, takeover: true)
    assert %{records: 4, blocks: 6, seq_events: 8} = report

    assert %RepoRoot{cid: cid, rev: rev} = Repo.get(RepoRoot, @did)
    assert cid == base.root_cid and rev == base.rev
    assert Repo.aggregate(from(r in Record, where: r.did == @did), :count) == base.records
    assert Repo.aggregate(from(b in RepoBlock, where: b.did == @did), :count) == base.blocks
    assert Repo.one(from(s in RepoSeq, where: s.did == @did, select: max(s.seq))) == base.max_seq

    assert Repo.one(
             from(s in RepoSeq, where: s.did == @did and s.seq == ^base.max_seq, select: s.event)
           ) == base.last_event

    # login through our verifier, by handle and by DID (handle_domains_survive_migration)
    assert {:ok, %{did: @did, handle: @handle}, nil} = Accounts.login(@handle, @password)
    assert {:ok, %{did: @did}, nil} = Accounts.login(@did, @password)
    assert {:error, :invalid_login} = Accounts.login(@did, "wrong")

    post = Verify.imported(@did, bundle, takeover: true, password: @password)
    assert post.ok?, inspect(post.checks)

    # the hostname changes on the way in: exactly one PLC op is listed, never submitted
    assert [%{did: @did, change: "#atproto_pds", from: "https://ref-pds.aerox.sola.town"}] =
             Verify.plc_ops_needed(bundle, Aerox.PDS.Config.hostname())

    # ---- and back out: PG → bundle → reference dir for 0.4 -------------
    out2 = Path.join(dir, "bundle2")
    assert {:ok, _} = Postgres.export(@did, out2, takeover: true, insecure_plaintext: true)
    assert {:ok, bundle2} = Bundle.read(out2)
    data = Path.join(dir, "pds-data")

    assert {:error, {:unsupported_pds_version, "0.3", _}} =
             ReferencePds.write(bundle2, data, pds_version: "0.3")

    assert {:ok, %{records: 4, blocks: 6, seq_events: 8}} =
             ReferencePds.write(bundle2, data, pds_version: "0.4", takeover: true)

    for {db, names} <- [
          {"account.sqlite", ~w(001 002 003 004 005 006 007)},
          {"sequencer.sqlite", ~w(001)},
          {Path.join(
             ReferencePds.actor_dir(data, @did) |> Path.relative_to(data),
             "store.sqlite"
           ), ~w(001)}
        ] do
      {:ok, conn} = Sqlite.open(Path.join(data, db))

      assert Enum.map(
               Sqlite.query(conn, "SELECT name FROM kysely_migration ORDER BY name"),
               & &1["name"]
             ) == names

      assert [%{"is_locked" => 0}] =
               Sqlite.query(conn, "SELECT is_locked FROM kysely_migration_lock")

      Sqlite.close(conn)
    end

    assert File.read!(Path.join(ReferencePds.actor_dir(data, @did), "key")) ==
             File.read!(Path.join(ReferencePds.actor_dir(@fixture, @did), "key"))

    # the written directory reads back to the same repo, rows and seq log as the fixture
    assert {:ok, round} = ReferencePds.contents(data, @did, takeover: true)
    {:ok, original} = ReferencePds.contents(@fixture, @did, takeover: true)
    assert round.repo_car == original.repo_car
    assert round.state == original.state
    assert Map.drop(round.account, ["preferences"]) == Map.drop(original.account, ["preferences"])
    assert elem(round.seq, 0) == elem(original.seq, 0)

    {:ok, conn} = Sqlite.open(Path.join(ReferencePds.actor_dir(data, @did), "store.sqlite"))
    assert [%{"n" => 6}] = Sqlite.query(conn, "SELECT count(*) AS n FROM repo_block")
    assert [%{"n" => 4}] = Sqlite.query(conn, "SELECT count(*) AS n FROM record")
    Sqlite.close(conn)
  end
end
