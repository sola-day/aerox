defmodule Aerox.ATProto.LexiconGoldenTest do
  @moduledoc "L4: indigo lexicon vectors (schema validity, record data verdicts) and the vendored registry."
  use Aerox.GoldenCase, async: true
  alias Aerox.ATProto.{Data, Lexicon}
  alias Aerox.ATProto.Lexicon.{Registry, Schema}

  @catalog "lexicon/catalog"
           |> golden_path()
           |> File.ls!()
           |> Enum.sort()
           |> Enum.map(&json_golden!("lexicon/catalog/#{&1}"))

  setup_all do
    {:ok, reg: Registry.new!(@catalog)}
  end

  test "lexicon-valid documents are accepted; lexicon-invalid ones are rejected" do
    for %{"name" => name, "lexicon" => doc} <- json_golden!("lexicon/lexicon-valid.json") do
      assert {:ok, _} = Schema.check_doc(doc), name
    end

    for %{"name" => name, "lexicon" => doc} <- json_golden!("lexicon/lexicon-invalid.json") do
      assert {:error, _} = Schema.check_doc(doc), name
    end
  end

  test "record-data-valid records validate against the catalog", %{reg: reg} do
    for %{"name" => name, "data" => data} <- json_golden!("lexicon/record-data-valid.json") do
      record = Data.from_json!(data)
      assert {:ok, _} = Lexicon.validate_record(reg, "example.lexicon.record", record), name
      assert {:ok, :valid} = Lexicon.record_status(reg, record, nil), name
    end
  end

  test "record-data-invalid records are rejected with a path", %{reg: reg} do
    for %{"name" => name, "data" => data} <- json_golden!("lexicon/record-data-invalid.json") do
      result =
        case Data.from_json(data) do
          {:ok, record} -> Lexicon.validate_record(reg, "example.lexicon.record", record)
          {:error, _} = e -> e
        end

      assert {:error, {msg, path}} = result, name
      assert is_binary(msg) and is_list(path), name
    end
  end

  test "defaults are filled and nullable fields pass", %{reg: reg} do
    assert {:ok, record} =
             Lexicon.validate_record(reg, "example.lexicon.record", %{
               "$type" => "example.lexicon.record",
               "integer" => 1,
               "nullableString" => nil
             })

    assert record["defaultInteger"] ==
             get_in(hd(Enum.filter(@catalog, &(&1["id"] == "example.lexicon.record"))), [
               "defs",
               "main",
               "record",
               "properties",
               "defaultInteger",
               "default"
             ])
  end

  test "record key rules" do
    reg =
      Registry.new!([
        %{
          "lexicon" => 1,
          "id" => "com.example.tidrec",
          "defs" => %{
            "main" => %{"type" => "record", "key" => "tid", "record" => %{"type" => "object"}}
          }
        },
        %{
          "lexicon" => 1,
          "id" => "com.example.self",
          "defs" => %{
            "main" => %{
              "type" => "record",
              "key" => "literal:self",
              "record" => %{"type" => "object"}
            }
          }
        }
      ])

    assert Lexicon.valid_record_key?(reg, "com.example.tidrec", "3jzfcijpj2z2a")
    refute Lexicon.valid_record_key?(reg, "com.example.tidrec", "self")
    assert Lexicon.valid_record_key?(reg, "com.example.self", "self")
    refute Lexicon.valid_record_key?(reg, "com.example.self", "other")
    assert Lexicon.valid_record_key?(reg, "com.example.unknown", "anything-goes")
  end

  describe "the vendored registry" do
    test "loads every priv/lexicons document and every ref resolves" do
      reg = Lexicon.default_registry()
      assert map_size(reg.docs) == 345
      assert Registry.dangling_refs(reg) == []
      assert Registry.known?(reg, "com.atproto.repo.strongRef")
      assert Registry.known?(reg, "com.atproto.label.defs#label")
      assert Registry.known?(reg, "com.atproto.space.defs#signedCommit")
      assert Registry.known?(reg, "app.bsky.authFullApp")
      assert "com.atproto.lexicon.schema" in Registry.record_types(reg)
      assert "app.bsky.feed.post" in Registry.record_types(reg)
      assert length(Registry.defs_of_type(reg, "permission-set")) == 11
    end

    test "three-state record admission (DESIGN §6.3)" do
      reg = Lexicon.default_registry()

      post = %{
        "$type" => "app.bsky.feed.post",
        "text" => "hi",
        "createdAt" => "2026-09-09T00:00:00.000Z"
      }

      assert {:ok, :valid} = Lexicon.record_status(reg, post, nil)
      assert {:ok, :skipped} = Lexicon.record_status(reg, post, false)

      assert {:error, {:invalid_record, _, ["record", "text"]}} =
               Lexicon.record_status(reg, Map.put(post, "text", 1), nil)

      unknown = %{"$type" => "com.example.unknown", "x" => 1}
      assert {:ok, :unknown} = Lexicon.record_status(reg, unknown, nil)

      assert {:error, {:unknown_lexicon, "com.example.unknown"}} =
               Lexicon.record_status(reg, unknown, true)

      schema = %{"$type" => "com.atproto.lexicon.schema", "lexicon" => 1}
      assert {:ok, :valid} = Lexicon.record_status(reg, schema, nil)

      assert {:error, {:invalid_record, _, _}} =
               Lexicon.record_status(reg, %{"$type" => "com.atproto.lexicon.schema"}, nil)
    end

    test "xrpc params, input and output against real com.atproto schemas" do
      reg = Lexicon.default_registry()

      assert {:ok, %{"limit" => 50}} =
               Lexicon.validate_params(reg, "com.atproto.repo.listRecords", %{
                 "repo" => "did:plc:abc",
                 "collection" => "app.bsky.feed.post"
               })

      assert {:error, {_, ["limit"]}} =
               Lexicon.validate_params(reg, "com.atproto.repo.listRecords", %{
                 "repo" => "did:plc:abc",
                 "collection" => "app.bsky.feed.post",
                 "limit" => 101
               })

      assert {:error, {_, ["collection"]}} =
               Lexicon.validate_params(reg, "com.atproto.repo.listRecords", %{
                 "repo" => "did:plc:abc"
               })

      input = %{
        "repo" => "alice.test",
        "collection" => "app.bsky.feed.post",
        "record" => %{"$type" => "app.bsky.feed.post", "text" => "hi"}
      }

      assert {:ok, _} = Lexicon.validate_input(reg, "com.atproto.repo.createRecord", input)

      assert {:error, {_, ["input", "record"]}} =
               Lexicon.validate_input(
                 reg,
                 "com.atproto.repo.createRecord",
                 Map.put(input, "record", "nope")
               )

      label = %{
        "src" => "did:plc:abc",
        "uri" => "at://did:plc:abc/app.bsky.feed.post/x",
        "val" => "spam",
        "cts" => "2026-09-09T00:00:00.000Z"
      }

      assert {:ok, _} = Lexicon.validate(reg, "com.atproto.label.defs#label", label)

      assert {:error, {_, ["src"]}} =
               Lexicon.validate(reg, "com.atproto.label.defs#label", %{
                 label
                 | "src" => "not a did"
               })

      assert {:ok, _} =
               Lexicon.validate_output(reg, "com.atproto.server.describeServer", %{
                 "did" => "did:web:pds.example",
                 "availableUserDomains" => [".example"]
               })

      assert {:ok, _} =
               Lexicon.validate_message(reg, "com.atproto.sync.subscribeRepos", %{
                 "$type" => "com.atproto.sync.subscribeRepos#identity",
                 "seq" => 1,
                 "did" => "did:plc:abc",
                 "time" => "2026-09-09T00:00:00.000Z"
               })

      assert {:error, _} =
               Lexicon.validate_message(reg, "com.atproto.sync.subscribeRepos", %{
                 "$type" => "com.atproto.sync.subscribeRepos#identity",
                 "seq" => 1
               })
    end
  end
end
