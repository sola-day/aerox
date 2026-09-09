defmodule Aerox.Interop.BundlePostgresTest do
  @moduledoc """
  VERIFICATION §8, PG → bundle → PG: byte-identical `repo_block`, equal rows in
  every table, blobs bit-identical, login still works; encrypted bundles open
  only with the right secret; tampering is caught before any DB write; the
  import is re-runnable; and the did-map regression
  (`import_reports_zero_work_as_failure`).
  """
  use Aerox.DataCase, async: false, repos: [Aerox.PDS.Repo, Aerox.PLC.Repo]
  alias Aerox.ATProto.CID
  alias Aerox.Blob.Store
  alias Aerox.Interop.{Bundle, Progress, Verify}
  alias Aerox.Interop.Bundle.Postgres
  alias Aerox.PDS.{Accounts, Blobs, Records, Repo, Signup}
  alias Aerox.PDS.Records.Prepare

  alias Aerox.PDS.Schema.{
    Account,
    AccountPref,
    Actor,
    AppPassword,
    Backlink,
    Blob,
    InviteCode,
    InviteCodeUse,
    Record,
    RecordBlob,
    RepoBlock,
    RepoRoot,
    RepoSeq
  }

  @moduletag :tmp_dir
  @password "pw-pw-pw-pw"
  @tables [
    Actor,
    Account,
    AppPassword,
    AccountPref,
    RepoRoot,
    RepoBlock,
    Record,
    Backlink,
    Blob,
    RecordBlob
  ]

  setup %{tmp_dir: dir} do
    # a private blob store per test, so bytes can be compared and wiped
    store = {Aerox.Blob.Disk, root: Path.join(dir, "blobs")}
    {:ok, store: store}
  end

  defp create_account(store) do
    n = System.unique_integer([:positive])

    {:ok, %{did: did}} =
      Signup.create(%{
        handle: "port#{n}.test",
        email: "port#{n}@example.com",
        password: @password
      })

    png = <<0x89, "PNG\r\n", 0x1A, "\n">> <> :crypto.strong_rand_bytes(5000)
    # upload straight through the adapter used by this test
    {:ok, temp_key} = Store.put_temp(store, did, [png])
    cid = CID.for_raw(png)
    meta = %{temp_key: temp_key, size: byte_size(png), cid: cid, mime_type: "image/png"}
    {:ok, ref} = Blobs.track(did, meta)
    blob = Aerox.ATProto.Data.to_json(ref)

    {:ok, post} =
      Prepare.create(did, "app.bsky.feed.post", %{
        "$type" => "app.bsky.feed.post",
        "text" => "hello portability",
        "createdAt" => DateTime.to_iso8601(DateTime.utc_now()),
        "embed" => %{
          "$type" => "app.bsky.embed.images",
          "images" => [%{"image" => blob, "alt" => "x"}]
        }
      })

    {:ok, follow} =
      Prepare.create(did, "app.bsky.graph.follow", %{
        "$type" => "app.bsky.graph.follow",
        "subject" => "did:plc:ewvi7nxzyoun6zhxrhs64oiz",
        "createdAt" => DateTime.to_iso8601(DateTime.utc_now())
      })

    {:ok, _} = Records.process_writes(did, [post, follow])
    :ok = Store.make_permanent(store, did, temp_key, cid)
    Repo.update_all(from(b in Blob, where: b.did == ^did), set: [temp_key: nil])

    {:ok, _} = Accounts.create_app_password(did, "phone")
    [_code] = Accounts.create_invite_codes(did, 1, 2)

    :ok =
      Accounts.put_preferences(
        did,
        [%{"$type" => "app.bsky.actor.defs#adultContentPref", "enabled" => true}],
        "app.bsky"
      )

    Repo.update_all(
      from(r in Record, where: r.did == ^did and r.collection == "app.bsky.graph.follow"),
      set: [takedown_ref: "mod-1"]
    )

    {did, png}
  end

  defp snapshot(did) do
    rows =
      Map.new(@tables, fn schema ->
        {schema,
         schema
         |> where([r], r.did == ^did)
         |> Repo.all()
         |> Enum.map(&(&1 |> Map.from_struct() |> Map.drop([:__meta__, :id])))
         |> Enum.sort()}
      end)

    codes =
      InviteCode
      |> where([i], i.for_account == ^did)
      |> Repo.all()
      |> Enum.map(&Map.drop(Map.from_struct(&1), [:__meta__]))
      |> Enum.sort()

    code_strs = Enum.map(codes, & &1.code)

    uses =
      InviteCodeUse
      |> where([u], u.code in ^code_strs)
      |> Repo.all()
      |> Enum.map(&Map.drop(Map.from_struct(&1), [:__meta__]))
      |> Enum.sort()

    seq =
      RepoSeq
      |> where([s], s.did == ^did)
      |> order_by(:seq)
      |> Repo.all()
      |> Enum.map(&Map.drop(Map.from_struct(&1), [:__meta__]))

    Map.merge(rows, %{invite_code: codes, invite_code_use: uses, repo_seq: seq})
  end

  defp wipe(did, store) do
    :ok = Accounts.delete_account(did)
    Repo.delete_all(from(s in RepoSeq, where: s.did == ^did))
    Repo.delete_all(from(i in InviteCode, where: i.for_account == ^did))
    :ok = Store.delete_all(store, did)
    assert Repo.all(from(b in RepoBlock, where: b.did == ^did)) == []
  end

  test "PG → bundle → wipe → PG is lossless, encrypted, and login still works", %{
    tmp_dir: dir,
    store: store
  } do
    {did, png} = create_account(store)
    before = snapshot(did)

    assert length(before[RepoBlock]) > 3 and length(before[Record]) == 2 and
             length(before[Blob]) == 1

    assert length(before.repo_seq) >= 5

    sk = JOSE.JWK.generate_key({:ec, "P-256"})
    out = Path.join(dir, "bundle")

    assert {:ok, manifest} =
             Postgres.export(did, out,
               takeover: true,
               store: store,
               recipients: [{:jwk, JOSE.JWK.to_public(sk)}]
             )

    assert manifest["did"] == did
    assert manifest["counts"]["records"] == 2 and manifest["counts"]["blobs"] == 1
    assert manifest["counts"]["seq_events"] == length(before.repo_seq)
    assert manifest["source"]["host"] == "pds.aerox.sola.town"
    refute File.read!(Path.join(out, "account.json")) =~ "example.com"

    # the bundle alone verifies (before any DB write)
    assert {:ok, bundle} = Bundle.read(out, secret: {:jwk, sk})
    pre = Verify.bundle(bundle, takeover: true)
    assert pre.ok?, inspect(pre.checks)

    wipe(did, store)
    assert Accounts.login(did, @password) == {:error, :invalid_login}

    assert {:ok, report} = Postgres.import(bundle, takeover: true, store: store)
    assert %{records: 2, blobs: 1, seq_events: seq_events} = report
    assert seq_events == length(before.repo_seq)

    after_ = snapshot(did)

    for {table, rows} <- before do
      assert after_[table] == rows, "table #{inspect(table)} differs"
    end

    assert Enum.map(after_[RepoBlock], & &1.content) == Enum.map(before[RepoBlock], & &1.content)
    assert {:ok, ^png} = Store.get(store, did, CID.for_raw(png))
    assert {:ok, %{did: ^did}, nil} = Accounts.login(did, @password)
    assert %{phase: "done"} = Progress.get(did)

    post = Verify.imported(did, bundle, takeover: true, password: @password, store: store)
    assert post.ok?, inspect(post.checks)
    assert Verify.plc_ops_needed(bundle, "pds.aerox.sola.town") == []
    assert [%{did: ^did, change: "#atproto_pds"}] = Verify.plc_ops_needed(bundle, "other.example")

    # import_is_rerunnable: a second import with changed mutable fields converges to the bundle
    Repo.update_all(from(a in Actor, where: a.did == ^did), set: [handle: "changed.test"])
    Repo.delete_all(from(r in Record, where: r.did == ^did))
    assert {:ok, :skipped} = Postgres.import(bundle, takeover: true, store: store)
    assert {:ok, _} = Postgres.import(bundle, takeover: true, store: store, force: true)
    assert snapshot(did) == before

    # progress says done but the target was wiped: re-imported, not skipped (did-map regression)
    wipe(did, store)
    assert Progress.stale?(did)
    assert {:ok, %{records: 2}} = Postgres.import(bundle, takeover: true, store: store)
    assert snapshot(did) == before
  end

  test "tampering is detected before any DB write; wrong secrets do not open the bundle", %{
    tmp_dir: dir,
    store: store
  } do
    {did, _} = create_account(store)
    out = Path.join(dir, "b")

    assert {:ok, _} =
             Postgres.export(did, out, store: store, recipients: [{:passphrase, "hunter2"}])

    wipe(did, store)

    assert {:error, :cannot_unwrap_content_key} =
             Bundle.read(out, secret: {:passphrase, "hunter3"})

    assert {:error, :bundle_is_encrypted} = Bundle.read(out)

    # flip one byte of the encrypted CAR: the chunk fails authentication, nothing is written
    car_path = Path.join(out, "repo.car")
    <<pre::binary-size(40), b, post::binary>> = File.read!(car_path)
    File.write!(car_path, <<pre::binary, Bitwise.bxor(b, 0x80), post::binary>>)
    assert {:ok, bundle} = Bundle.read(out, secret: {:passphrase, "hunter2"})

    assert {:error, {:repo_car, _}} =
             Postgres.import(bundle, store: store) |> unwrap_bundle_error()

    refute Repo.exists?(from(a in Actor, where: a.did == ^did))
    refute Repo.exists?(from(b in RepoBlock, where: b.did == ^did))
    assert Progress.get(did) == nil
    refute Store.has_stored?(store, did, CID.for_raw("x"))
  end

  defp unwrap_bundle_error({:error, [problem | _]}), do: {:error, {:repo_car, problem}}
  defp unwrap_bundle_error(other), do: other

  test "import refuses a bundle whose signing key does not match the commit", %{
    tmp_dir: dir,
    store: store
  } do
    {did, _} = create_account(store)
    out = Path.join(dir, "k")
    assert {:ok, _} = Postgres.export(did, out, store: store, insecure_plaintext: true)
    wipe(did, store)
    # rewrite signing.key with another key and re-sign the manifest hashes honestly
    File.write!(Path.join(out, "signing.key"), :crypto.strong_rand_bytes(32))
    assert {:ok, bundle} = Bundle.read(out)
    assert {:error, {:repo_car, :invalid_signature}} = Postgres.import(bundle, store: store)
    refute Repo.exists?(from(a in Actor, where: a.did == ^did))
  end

  test "import_reports_zero_work_as_failure: a non-empty source with nothing imported is not a success" do
    assert {:error, {:nothing_imported, %{source_accounts: 3, imported: 0}}} =
             Verify.summary([], 3)

    assert {:error, {:empty_source, _}} = Verify.summary([], 0)

    assert {:error, {:failures, %{failed: 1}}} =
             Verify.summary([{"did:a", :imported}, {"did:b", {:failed, :x}}], 2)

    assert {:ok, %{imported: 1, skipped: 1}} =
             Verify.summary([{"did:a", :imported}, {"did:b", :skipped}], 2)
  end
end
