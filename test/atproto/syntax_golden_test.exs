defmodule Aerox.ATProto.SyntaxGoldenTest do
  @moduledoc "L0: every `interop-test-files/syntax` vector, line by line (VERIFICATION §3.1)."
  use Aerox.GoldenCase, async: true
  alias Aerox.ATProto.Syntax

  @kinds [
    {"handle", &Syntax.valid_handle?/1, &Syntax.ensure_valid_handle/1},
    {"nsid", &Syntax.valid_nsid?/1, &Syntax.ensure_valid_nsid/1},
    {"did", &Syntax.valid_did?/1, &Syntax.ensure_valid_did/1},
    {"atidentifier", &Syntax.valid_at_identifier?/1, &Syntax.ensure_valid_at_identifier/1},
    {"aturi", &Syntax.valid_at_uri?/1, &Syntax.ensure_valid_at_uri/1},
    {"recordkey", &Syntax.valid_record_key?/1, &Syntax.ensure_valid_record_key/1},
    {"tid", &Syntax.valid_tid?/1, &Syntax.ensure_valid_tid/1},
    {"datetime", &Syntax.valid_datetime?/1, &Syntax.ensure_valid_datetime/1}
  ]

  for {kind, pred, ensure} <- @kinds do
    test "#{kind}: every valid vector is accepted by both the predicate and ensure" do
      for line <- lines("syntax/#{unquote(kind)}_syntax_valid.txt") do
        assert unquote(pred).(line), "expected valid: #{inspect(line)}"
        assert :ok = unquote(ensure).(line), "expected :ok: #{inspect(line)}"
      end
    end

    test "#{kind}: every invalid vector is rejected by both, with a reason" do
      for line <- lines("syntax/#{unquote(kind)}_syntax_invalid.txt") do
        refute unquote(pred).(line), "expected invalid: #{inspect(line)}"
        assert {:error, reason} = unquote(ensure).(line), "expected error: #{inspect(line)}"
        assert is_binary(reason) and reason != ""
      end
    end
  end

  test "datetime: syntactically fine but semantically impossible dates are rejected" do
    for line <- lines("syntax/datetime_parse_invalid.txt") do
      assert {:error, _} = Syntax.parse_datetime(line), "expected parse failure: #{inspect(line)}"
    end
  end

  test "datetime: valid vectors parse, and the preferred format round-trips at millisecond precision" do
    for line <- lines("syntax/datetime_syntax_valid.txt") do
      assert {:ok, %DateTime{} = dt} = Syntax.parse_datetime(line)
      formatted = Syntax.format_datetime(dt)
      assert Regex.match?(~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/, formatted)
      assert {:ok, back} = Syntax.parse_datetime(formatted)
      assert DateTime.compare(DateTime.truncate(dt, :millisecond), back) == :eq
    end
  end
end
