defmodule Aerox.PLC.DirectoryTest do
  @moduledoc "L6 PLC (VERIFICATION §5): admission under the row lock, nullification within 72 h and refusal after, export, audited removeInvalidOps, and replay of the interop logs through the real database."
  use Aerox.DataCase, async: true, repos: [Aerox.PLC.Repo]
  import Aerox.GoldenCase, only: [json_golden!: 1, golden_path: 1]
  import ExUnit.CaptureLog
  alias Aerox.ATProto.Crypto
  alias Aerox.PLC.{Directory, Operations}

  @moduletag :service

  setup do
    rotation = Crypto.generate(:k256)
    recovery = Crypto.generate(:p256)

    {genesis, did} =
      Operations.create_op(
        [
          signing_key: Crypto.did_key(rotation),
          handle: "alice.test",
          pds: "https://pds.test",
          rotation_keys: [Crypto.did_key(recovery), Crypto.did_key(rotation)]
        ],
        rotation
      )

    {:ok, did: did, genesis: genesis, rotation: rotation, recovery: recovery}
  end

  test "create, read back as document, update, export", %{
    did: did,
    genesis: genesis,
    rotation: rotation
  } do
    t0 = ~U[2026-09-09 10:00:00.000000Z]
    assert {:ok, _} = Directory.submit(did, genesis, t0)
    # resubmitting the genesis is a misordered op, as upstream: prev must point at history
    assert {:error, {:bad_request, "Operations not correctly ordered"}} =
             Directory.submit(did, genesis, DateTime.add(t0, 1))

    assert {:ok, doc} = Directory.did_document(did)
    assert doc["id"] == did and doc["alsoKnownAs"] == ["at://alice.test"]
    assert [%{"id" => "#atproto_pds", "serviceEndpoint" => "https://pds.test"}] = doc["service"]
    assert {:error, :not_found} = Directory.did_document("did:plc:aaaaaaaaaaaaaaaaaaaaaaaa")

    update = Operations.atproto_update_op(genesis, rotation, handle: "alice2.test")
    assert {:ok, _} = Directory.submit(did, update, DateTime.add(t0, 60))
    assert {:ok, %{"alsoKnownAs" => ["at://alice2.test"]}} = Directory.did_document(did)
    assert [%{"nullified" => false}, %{"nullified" => false}] = Directory.audit_log(did)

    assert [first, second] = Directory.export(10, t0 |> DateTime.add(-1))
    assert first["cid"] == to_string(Operations.cid(genesis)) and second["did"] == did
    assert [] = Directory.export(10, DateTime.add(t0, 61))
    assert [%{"type" => "sequenced_op", "seq" => seq}] = Directory.export(1, 0)
    assert [%{"seq" => seq2}] = Directory.export(1, seq)
    assert seq2 > seq
  end

  test "recovery nullifies within 72 h and is refused after", %{
    did: did,
    genesis: genesis,
    rotation: rotation,
    recovery: recovery
  } do
    t0 = ~U[2026-09-09 10:00:00.000000Z]
    {:ok, _} = Directory.submit(did, genesis, t0)

    hijack =
      Operations.atproto_update_op(genesis, rotation, rotation_keys: [Crypto.did_key(rotation)])

    {:ok, _} = Directory.submit(did, hijack, DateTime.add(t0, 60))

    recover =
      Operations.atproto_update_op(genesis, recovery, rotation_keys: [Crypto.did_key(recovery)])

    assert {:error, {:bad_request, "Recovery operation occurred outside" <> _}} =
             Directory.submit(did, recover, DateTime.add(t0, 73 * 3600))

    assert {:ok, _} = Directory.submit(did, recover, DateTime.add(t0, 3600))

    assert [%{"nullified" => false}, %{"nullified" => true}, %{"nullified" => false}] =
             Directory.audit_log(did)

    assert {:ok, %{rotation_keys: [k]}} = Directory.document_data(did)
    assert k == Crypto.did_key(recovery)
    assert length(Directory.indexed_ops(did, false)) == 2
  end

  test "tombstone hides the document; further ops are refused", %{
    did: did,
    genesis: genesis,
    rotation: rotation
  } do
    t0 = ~U[2026-09-09 10:00:00.000000Z]
    {:ok, _} = Directory.submit(did, genesis, t0)
    tomb = Operations.tombstone_op(Operations.cid(genesis), rotation)
    {:ok, _} = Directory.submit(did, tomb, DateTime.add(t0, 1))
    assert {:error, :tombstoned} = Directory.did_document(did)

    assert {:error, {:bad_request, _}} =
             Directory.submit(
               did,
               Operations.atproto_update_op(genesis, rotation, handle: "x.test"),
               DateTime.add(t0, 2)
             )
  end

  test "rate limit: an eleventh op within an hour is refused", %{
    did: did,
    genesis: genesis,
    rotation: rotation
  } do
    t0 = ~U[2026-09-09 10:00:00.000000Z]
    {:ok, _} = Directory.submit(did, genesis, t0)

    last =
      Enum.reduce(1..9, genesis, fn i, prev ->
        op = Operations.atproto_update_op(prev, rotation, handle: "h#{i}.test")
        {:ok, _} = Directory.submit(did, op, DateTime.add(t0, i))
        op
      end)

    assert {:error, {:bad_request, "To many operations within last hour" <> _}} =
             Directory.submit(
               did,
               Operations.atproto_update_op(last, rotation, handle: "h10.test"),
               DateTime.add(t0, 10)
             )
  end

  test "removeInvalidOps refuses valid ops, removes invalid ones and audits", %{
    did: did,
    genesis: genesis
  } do
    t0 = ~U[2026-09-09 10:00:00.000000Z]
    {:ok, _} = Directory.submit(did, genesis, t0)

    assert {:error, {:bad_request, "valid operations cannot be removed"}} =
             Directory.remove_invalid_ops(did, to_string(Operations.cid(genesis)))

    assert {:error, {:bad_request, "operation does not exist"}} =
             Directory.remove_invalid_ops(did, "bafyreiaaaa")

    # plant an op signed by a key that is not a rotation key, bypassing admission
    evil = Operations.atproto_update_op(genesis, Crypto.generate(:k256), handle: "evil.test")

    Aerox.PLC.Repo.insert!(%Aerox.PLC.Operation{
      did: did,
      cid: to_string(Operations.cid(evil)),
      operation: evil,
      nullified: false,
      created_at: DateTime.add(t0, 5)
    })

    assert {:ok, %{"alsoKnownAs" => ["at://evil.test"]}} = Directory.did_document(did)

    {result, log} =
      with_log(fn -> Directory.remove_invalid_ops(did, to_string(Operations.cid(evil))) end)

    assert {:ok, [removed]} = result
    assert log =~ "removed invalid operation"
    assert removed["cid"] == to_string(Operations.cid(evil))
    assert {:ok, %{"alsoKnownAs" => ["at://alice.test"]}} = Directory.did_document(did)

    assert [%{type: "removeInvalidOps", data: %{"did" => ^did}}] =
             Aerox.PLC.Repo.all(Aerox.PLC.AdminLog)
  end

  test "the interop audit logs replay through the database with the same nullification flags" do
    for file <-
          "plc/valid"
          |> golden_path()
          |> File.ls!()
          |> Enum.reject(&String.contains?(&1, "legacy")) do
      log = json_golden!("plc/valid/#{file}")
      did = hd(log)["did"]

      for entry <- log do
        {:ok, at, _} = DateTime.from_iso8601(entry["createdAt"])

        assert {:ok, _} = Directory.submit(did, entry["operation"], at),
               "#{file}: #{entry["cid"]}"
      end

      assert Enum.map(Directory.audit_log(did), & &1["nullified"]) ==
               Enum.map(log, & &1["nullified"]),
             file
    end
  end
end
