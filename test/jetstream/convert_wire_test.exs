defmodule Aerox.Jetstream.ConvertWireTest do
  @moduledoc "Relay events to rows (with the validation gate), rows to v1 and v2 frames, and dictionary compression."
  use Aerox.GoldenCase, async: true
  alias Aerox.ATProto.{Bytes, CID, Data, DagCBOR}
  alias Aerox.Jetstream.{Convert, Event, Wire}

  defp golden_commit(seq),
    do: Data.from_json!(json_golden!("firehose/firehose_commit_#{seq}.json"))

  test "a real relay commit becomes one row per op, records as the repo's bytes" do
    body = golden_commit(4_621_317_332)
    {rows, drops} = Convert.rows("#commit", body)
    assert drops == []
    assert length(rows) == length(body["ops"])

    for {row, op} <- Enum.zip(rows, body["ops"]) do
      [collection, rkey] = String.split(op["path"], "/")

      assert {row.did, row.collection, row.rkey, row.rev} ==
               {body["repo"], collection, rkey, body["rev"]}

      case op["action"] do
        "delete" ->
          assert row.kind == :delete and row.payload == ""

        action ->
          assert row.kind == String.to_atom(action)
          assert CID.for_cbor(row.payload) == op["cid"]
      end
    end
  end

  test "the validation gate: bad rev drops the event, bad paths and missing blocks drop the op" do
    body = golden_commit(4_621_317_332)
    assert {[], [{:invalid_rev, _}]} = Convert.rows("#commit", %{body | "rev" => "not-a-tid"})

    [op | _] = body["ops"]

    bad_ops = [
      %{op | "path" => "not an nsid/abc"},
      %{op | "path" => "app.bsky.feed.post/bad rkey!"},
      %{op | "path" => "$account/self"},
      %{op | "action" => "create", "cid" => CID.for_cbor(DagCBOR.encode(%{"no" => "block"}))}
    ]

    {rows, drops} = Convert.rows("#commit", %{body | "ops" => bad_ops ++ [op]})
    assert length(rows) == 1

    assert Enum.map(drops, &elem(&1, 0)) == [
             :invalid_collection,
             :invalid_rkey,
             :invalid_collection,
             :missing_block
           ]

    assert {[%Event{kind: :identity, did: "did:plc:x", payload: p}], []} =
             Convert.rows("#identity", %{
               "did" => "did:plc:x",
               "handle" => "x.test",
               "seq" => 5,
               "time" => "2026-09-15T00:00:00.000Z"
             })

    assert {:ok, %{"handle" => "x.test"}} = DagCBOR.decode(p)

    assert {[], [{:invalid_rev, _}]} =
             Convert.rows("#sync", %{
               "did" => "did:plc:x",
               "rev" => "nope",
               "blocks" => Bytes.new("")
             })
  end

  test "v1 and v2 frames" do
    record = %{
      "$type" => "app.bsky.feed.like",
      "createdAt" => "2024-09-09T19:46:02.102Z",
      "subject" => %{
        "uri" => "at://did:plc:a/app.bsky.feed.post/3l3pte3p2e325",
        "cid" => "bafyreidc6sydkkbchcyg62v77wbhzvb2mvytlmsychqgwf2xojjtirmzj4"
      }
    }

    payload = DagCBOR.encode(record)

    create = %Event{
      seq: 12_345,
      witnessed_at: 1_725_911_162_329_308,
      kind: :create,
      did: "did:plc:eygmaihciaxprqvxpfvl6flk",
      collection: "app.bsky.feed.like",
      rkey: "3l3qo2vuowo2b",
      rev: "3l3qo2vutsw2b",
      payload: payload
    }

    assert {:ok, v1} = Wire.v1(create)

    assert Jason.decode!(v1) == %{
             "did" => "did:plc:eygmaihciaxprqvxpfvl6flk",
             "time_us" => 1_725_911_162_329_308,
             "cursor" => 12_345,
             "kind" => "commit",
             "commit" => %{
               "rev" => "3l3qo2vutsw2b",
               "operation" => "create",
               "collection" => "app.bsky.feed.like",
               "rkey" => "3l3qo2vuowo2b",
               "record" => record,
               "cid" => Convert.cid(payload)
             }
           }

    assert {:ok, v2} = Wire.v2(%{create | indexed_at: 1_725_911_000_000_001})
    assert %{"$type" => "message", "payload" => p} = Jason.decode!(v2)
    assert p["$type"] == "network.bsky.jetstream.subscribeEvents#commit"

    assert {p["seq"], p["time"], p["operation"], p["record"]} ==
             {12_345, "2024-09-09T19:43:20.000001Z", "create", record}

    delete = %{create | kind: :delete, payload: ""}
    assert {:ok, d1} = Wire.v1(delete)
    refute Map.has_key?(Jason.decode!(d1)["commit"], "record")

    account = %Event{
      seq: 9,
      witnessed_at: 1,
      kind: :account,
      did: "did:plc:a",
      payload:
        DagCBOR.encode(%{
          "did" => "did:plc:a",
          "active" => true,
          "seq" => 77,
          "time" => "2024-09-05T06:11:04.870Z"
        })
    }

    assert Jason.decode!(elem(Wire.v1(account), 1)) |> Map.take(["kind", "account"]) ==
             %{
               "kind" => "account",
               "account" => %{
                 "did" => "did:plc:a",
                 "active" => true,
                 "seq" => 77,
                 "time" => "2024-09-05T06:11:04.870Z"
               }
             }

    sync = %Event{
      seq: 10,
      witnessed_at: 1,
      kind: :sync,
      did: "did:plc:a",
      rev: "3l3qo2vutsw2b",
      payload:
        DagCBOR.encode(%{
          "did" => "did:plc:a",
          "rev" => "3l3qo2vutsw2b",
          "blocks" => Bytes.new(<<1, 2>>),
          "seq" => 1,
          "time" => "2024-09-05T06:11:04.870Z"
        })
    }

    assert Wire.v1(sync) == :skip
    assert Wire.v1(%{create | kind: :create_resync}) == :skip

    assert %{
             "payload" => %{
               "$type" => "network.bsky.jetstream.subscribeEvents#sync",
               "sync" => %{"blocks" => %{"$bytes" => _}}
             }
           } =
             Jason.decode!(elem(Wire.v2(sync), 1))

    assert Jason.decode!(Wire.v2_error("ConsumerTooSlow", "slow")) == %{
             "$type" => "error",
             "error" => "ConsumerTooSlow",
             "message" => "slow"
           }
  end

  test "dictionary compression round-trips; the v2 dictionary is id 20260811" do
    assert Wire.dictionary_id(:v2) == 20_260_811
    frame = ~s({"$type":"message","payload":{"did":"did:plc:x"}})
    z = Wire.compress(:v2, frame)
    assert {:ok, %{dictID: 20_260_811}} = :zstd.get_frame_header(z)
    assert Wire.decompress(:v2, z) == frame
    assert Wire.decompress(:v1, Wire.compress(:v1, frame)) == frame
  end
end
