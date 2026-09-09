defmodule Aerox.PLC.OperationsGoldenTest do
  @moduledoc "did-method-plc interop audit logs (VERIFICATION §5 PLC): every valid log replays, every invalid one is refused."
  use Aerox.GoldenCase, async: true
  alias Aerox.ATProto.{CID, Crypto}
  alias Aerox.PLC.Operations

  @valid "plc/valid" |> golden_path() |> File.ls!() |> Enum.sort()
  @invalid "plc/invalid" |> golden_path() |> File.ls!() |> Enum.sort()

  for file <- @valid do
    test "valid: #{file}" do
      log = json_golden!("plc/valid/#{unquote(file)}")
      assert :ok = Operations.validate_audit_log(log)

      # the bare op log (nullified ops removed) also replays to a document or a tombstone
      ops = log |> Enum.reject(& &1["nullified"]) |> Enum.map(& &1["operation"])
      did = hd(log)["did"]
      assert {:ok, data} = Operations.validate_operation_log(did, ops)

      if data do
        doc = Operations.format_did_doc(data)
        assert doc["id"] == did
        assert Aerox.ATProto.Identity.valid_doc?(doc)
      else
        assert Operations.tombstone?(List.last(ops))
      end

      for entry <- log,
          do: assert(CID.to_string(Operations.cid(entry["operation"])) == entry["cid"])

      assert Operations.did_for_create_op(hd(log)["operation"]) == did
    end
  end

  for file <- @invalid do
    test "invalid: #{file}" do
      log = json_golden!("plc/invalid/#{unquote(file)}")
      assert {:error, _} = Operations.validate_audit_log(log)
    end
  end

  test "create, update, tombstone with our own keys round-trip through the rules" do
    rotation = Crypto.generate(:k256)
    recovery = Crypto.generate(:p256)
    signing = Crypto.generate(:k256)

    {genesis, did} =
      Operations.create_op(
        [
          signing_key: Crypto.did_key(signing),
          handle: "alice.test",
          pds: "pds.test",
          rotation_keys: [Crypto.did_key(recovery), Crypto.did_key(rotation)]
        ],
        rotation
      )

    assert Operations.valid_plc_did?(did)
    assert :ok = Operations.check_incoming_op(genesis)

    assert {:ok, %{nullified: [], prev: nil}} =
             Operations.assure_valid_next_op(did, [], genesis, ~U[2026-09-09 00:00:00Z])

    assert {:error, %{kind: :genesis_hash}} =
             Operations.assure_valid_creation_op("did:plc:aaaaaaaaaaaaaaaaaaaaaaaa", genesis)

    t0 = ~U[2026-09-09 00:00:00Z]

    indexed = [
      %{
        did: did,
        operation: genesis,
        cid: Operations.cid(genesis),
        nullified: false,
        created_at: t0
      }
    ]

    update =
      Operations.atproto_update_op(genesis, rotation,
        handle: "alice2.test",
        pds: "https://pds2.test"
      )

    assert update["alsoKnownAs"] == ["at://alice2.test"]
    assert update["services"]["atproto_pds"]["endpoint"] == "https://pds2.test"

    assert {:ok, %{nullified: [], prev: prev}} =
             Operations.assure_valid_next_op(did, indexed, update, DateTime.add(t0, 60))

    assert prev == Operations.cid(genesis)

    bogus = Operations.atproto_update_op(genesis, signing, handle: "evil.test")

    assert {:error, %{kind: :invalid_signature}} =
             Operations.assure_valid_next_op(did, indexed, bogus, DateTime.add(t0, 60))

    indexed2 =
      indexed ++
        [
          %{
            did: did,
            operation: update,
            cid: Operations.cid(update),
            nullified: false,
            created_at: DateTime.add(t0, 60)
          }
        ]

    recover =
      Operations.atproto_update_op(genesis, recovery, rotation_keys: [Crypto.did_key(recovery)])

    assert {:ok, %{nullified: [nullified]}} =
             Operations.assure_valid_next_op(did, indexed2, recover, DateTime.add(t0, 3600))

    assert nullified == Operations.cid(update)

    assert {:error, %{kind: :late_recovery}} =
             Operations.assure_valid_next_op(did, indexed2, recover, DateTime.add(t0, 73 * 3600))

    weaker = Operations.atproto_update_op(genesis, rotation, handle: "back.test")

    assert {:error, %{kind: :invalid_signature}} =
             Operations.assure_valid_next_op(did, indexed2, weaker, DateTime.add(t0, 3600))

    tomb = Operations.tombstone_op(Operations.cid(update), rotation)

    assert {:ok, %{nullified: []}} =
             Operations.assure_valid_next_op(did, indexed2, tomb, DateTime.add(t0, 120))

    assert :ok = Operations.check_incoming_op(tomb)
    assert {:ok, nil} = Operations.validate_operation_log(did, [genesis, update, tomb])

    assert {:error, %{kind: :misordered}} =
             Operations.validate_operation_log(did, [genesis, tomb, update])
  end

  test "incoming-op constraints" do
    rotation = Crypto.generate(:k256)

    {genesis, _} =
      Operations.create_op(
        [
          signing_key: Crypto.did_key(rotation),
          handle: "a.test",
          pds: "pds.test",
          rotation_keys: [Crypto.did_key(rotation)]
        ],
        rotation
      )

    assert {:error, "To many alsoKnownAs" <> _} =
             Operations.check_incoming_op(%{
               genesis
               | "alsoKnownAs" => Enum.map(1..11, &"at://h#{&1}.test")
             })

    assert {:error, "duplicate alsoKnownAs" <> _} =
             Operations.check_incoming_op(%{
               genesis
               | "alsoKnownAs" => ["at://a.test", "at://a.test"]
             })

    assert {:error, "Invalid rotationKey"} =
             Operations.check_incoming_op(%{genesis | "rotationKeys" => ["did:key:nope"]})

    assert {:error, "Not a valid operation" <> _} =
             Operations.check_incoming_op(Map.put(genesis, "extra", 1))

    assert {:error, "Operation too large" <> _} =
             Operations.check_incoming_op(%{
               genesis
               | "alsoKnownAs" => [String.duplicate("a", 5000)]
             })
  end
end
