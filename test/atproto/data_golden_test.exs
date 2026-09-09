defmodule Aerox.ATProto.DataGoldenTest do
  @moduledoc "L4 data-model verdicts against indigo `atdata/testdata` (VERIFICATION §3.1)."
  use Aerox.GoldenCase, async: true
  alias Aerox.ATProto.{CID, Data}

  test "every valid vector is accepted as a top-level object" do
    for %{"note" => note, "json" => json} <- json_golden!("data-model/data-model-valid.json") do
      assert {:ok, value} = Data.from_json(json), note
      assert is_map(value), note
    end
  end

  test "every invalid vector is rejected, with a path" do
    for %{"note" => note, "json" => json} <- json_golden!("data-model/data-model-invalid.json") do
      result =
        case json do
          %{} -> Data.from_json(json)
          _ -> Data.validate_record(json, [])
        end

      assert {:error, {msg, path}} = result, note
      assert is_binary(msg) and is_list(path), note
    end
  end

  test "integer-like floats become integers; real floats are refused" do
    assert {:ok, %{"a" => 123}} = Data.from_json(%{"a" => 123.0})
    assert {:error, {_, ["a"]}} = Data.from_json(%{"a" => 123.5})
  end

  test "legacy blob refs are accepted on read and normalised, never produced" do
    cid = "bafkreiccldh766hwcnuxnf2wh6jgzepf2nlu2lvcllt63eww5p6chi4ity"

    assert {:ok, %{"b" => blob}} =
             Data.from_json(%{"b" => %{"cid" => cid, "mimeType" => "image/png"}})

    assert %{"$type" => "blob", "ref" => %CID{}, "mimeType" => "image/png", "size" => -1} = blob
    assert Data.to_json(blob)["ref"] == %{"$link" => cid}
    assert [^blob] = Data.blob_refs(%{"x" => [%{"y" => blob}]})
  end

  test "errors carry a path to the offending value" do
    assert {:error, {"floats are not allowed", ["a", 1, "b"]}} =
             Data.validate(%{"a" => [0, %{"b" => 1.5}]})

    assert {:error, {"nesting too deep", _}} =
             Data.validate(Enum.reduce(1..10, 0, fn _, acc -> [acc] end), max_depth: 5)

    assert {:error, {"integer out of range", ["i"]}} =
             Data.validate(%{"i" => 0x8000_0000_0000_0000})
  end
end
