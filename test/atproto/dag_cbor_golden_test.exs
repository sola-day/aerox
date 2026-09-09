defmodule Aerox.ATProto.DagCBORGoldenTest do
  @moduledoc """
  L1 (VERIFICATION §3.1): every generated `@ipld/dag-cbor` vector encodes to
  identical bytes, decodes back to the input, and yields the golden CID; the
  indigo data-model fixtures agree; every hand-written non-canonical mutation
  is rejected.
  """
  use Aerox.GoldenCase, async: true
  alias Aerox.ATProto.{Bytes, CID, DagCBOR, Data}

  @vectors "dagcbor"
           |> golden_path()
           |> File.ls!()
           |> Enum.filter(&String.ends_with?(&1, ".cbor"))
           |> Enum.map(&String.trim_trailing(&1, ".cbor"))
           |> Enum.sort()

  for name <- @vectors do
    test "#{name}: encode is byte-identical, decode round-trips, CID matches" do
      name = unquote(name)
      input = Data.from_json!(json_golden!("dagcbor/#{name}.json"))
      expected = read_golden!("dagcbor/#{name}.cbor")
      cid = String.trim(read_golden!("dagcbor/#{name}.cid"))

      assert_bytes_equal(DagCBOR.encode(input), expected, name)
      assert {:ok, decoded} = DagCBOR.decode(expected)
      assert decoded == input
      assert CID.to_string(CID.for_cbor(expected)) == cid
      # re-encoding the decoded value is a fixed point
      assert_bytes_equal(DagCBOR.encode(decoded), expected, "#{name} re-encode")
    end
  end

  test "indigo data-model fixtures: json → cbor bytes → cid" do
    for %{"json" => json, "cbor_base64" => b64, "cid" => cid} <-
          json_golden!("data-model/data-model-fixtures.json") do
      expected = Base.decode64!(b64, padding: false)
      value = Data.from_json!(json)
      assert_bytes_equal(DagCBOR.encode(value), expected, cid)
      assert {:ok, ^value} = DagCBOR.decode(expected)
      assert CID.to_string(CID.for_cbor(expected)) == cid
      assert Data.to_json(value) == json
    end
  end

  test "indigo feedpost_record.cbor decodes, validates and re-encodes identically" do
    bytes = read_golden!("data-model/feedpost_record.cbor")
    assert {:ok, record} = Data.decode_cbor(bytes)
    assert record["$type"] == "app.bsky.feed.post"
    assert_bytes_equal(DagCBOR.encode(record), bytes)
  end

  test "cid vectors: string, binary and tag-42 forms" do
    for v <- json_golden!("cid/vectors.json") do
      bytes = Base.decode64!(v["bytesBase64"])

      cid =
        case v["codec"] do
          "dag-cbor" -> CID.for_cbor(bytes)
          "raw" -> CID.for_raw(bytes)
        end

      assert CID.to_string(cid) == v["cid"], v["name"]
      assert CID.to_bytes(cid) == Base.decode64!(v["cidBytesBase64"]), v["name"]
      assert {:ok, ^cid} = CID.parse(v["cid"])
      assert {:ok, ^cid} = CID.from_bytes(CID.to_bytes(cid))

      assert_bytes_equal(
        DagCBOR.encode(%{"x" => cid}),
        Base.decode64!(v["tag42Base64"]),
        "#{v["name"]} tag42"
      )

      assert CID.verify(cid, bytes)
    end
  end

  describe "strict decoder mutations (VERIFICATION §3.3)" do
    for file <- "dagcbor/invalid" |> golden_path() |> File.ls!() |> Enum.sort() do
      test "rejects #{file}" do
        bytes = read_golden!("dagcbor/invalid/#{unquote(file)}")
        assert {:error, _} = DagCBOR.decode(bytes)
      end
    end

    test "non-shortest integer" do
      assert {:error, :non_canonical_int} = DagCBOR.decode(<<0x18, 0x17>>)
      assert {:error, :non_canonical_int} = DagCBOR.decode(<<0x19, 0x00, 0xFF>>)
      assert {:error, :non_canonical_int} = DagCBOR.decode(<<0x1A, 0, 0, 0xFF, 0xFF>>)

      assert {:error, :non_canonical_int} =
               DagCBOR.decode(<<0x1B, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF>>)
    end

    test "non-shortest length" do
      assert {:error, :non_canonical_int} = DagCBOR.decode(<<0x78, 0x01, ?a>>)
      assert {:error, :non_canonical_int} = DagCBOR.decode(<<0x98, 0x00>>)
    end

    test "unsorted, duplicate and non-string keys" do
      assert {:error, :unsorted_keys} = DagCBOR.decode(<<0xA2, 0x61, ?b, 0x01, 0x61, ?a, 0x02>>)

      assert {:error, :unsorted_keys} =
               DagCBOR.decode(<<0xA2, 0x62, ?a, ?a, 0x01, 0x61, ?b, 0x02>>)

      assert {:error, :duplicate_key} = DagCBOR.decode(<<0xA2, 0x61, ?a, 0x01, 0x61, ?a, 0x02>>)
      assert {:error, :non_string_key} = DagCBOR.decode(<<0xA1, 0x01, 0x01>>)
    end

    test "tag 42 without the 0x00 prefix, and other tags" do
      cid = CID.for_cbor("x")
      bad = <<0xD8, 42, 0x58, 36>> <> CID.to_bytes(cid)
      assert {:error, {:invalid_cid, :missing_identity_prefix}} = DagCBOR.decode(bad)
      assert {:error, {:unsupported_tag, 1}} = DagCBOR.decode(<<0xC1, 0x00>>)
    end

    test "floats, undefined, indefinite lengths, trailing bytes, truncation" do
      assert {:error, :float_not_allowed} = DagCBOR.decode(<<0xFB, 0x3F, 0xF0, 0, 0, 0, 0, 0, 0>>)
      assert {:error, :float_not_allowed} = DagCBOR.decode(<<0xF9, 0x3C, 0x00>>)
      assert {:error, :undefined_not_allowed} = DagCBOR.decode(<<0xF7>>)
      assert {:error, :indefinite_length} = DagCBOR.decode(<<0x7F, 0x61, ?a, 0xFF>>)
      assert {:error, :indefinite_length} = DagCBOR.decode(<<0x9F, 0xFF>>)
      assert {:error, :trailing_bytes} = DagCBOR.decode(<<0x01, 0x02>>)
      assert {:error, :truncated} = DagCBOR.decode(<<0x62, ?a>>)
      assert {:error, :invalid_utf8} = DagCBOR.decode(<<0x61, 0xFF>>)
    end
  end

  test "encoder refuses atom keys, floats and out-of-range integers" do
    assert_raise ArgumentError, fn -> DagCBOR.encode(%{a: 1}) end
    assert_raise ArgumentError, fn -> DagCBOR.encode(1.5) end
    assert_raise ArgumentError, fn -> DagCBOR.encode(0x1_0000_0000_0000_0000) end

    assert DagCBOR.encode(0xFFFF_FFFF_FFFF_FFFF) ==
             <<0x1B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>

    assert DagCBOR.encode(-0x1_0000_0000_0000_0000) ==
             <<0x3B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>

    assert DagCBOR.encode(Bytes.new(<<>>)) == <<0x40>>
  end
end
