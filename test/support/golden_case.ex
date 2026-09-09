defmodule Aerox.GoldenCase do
  @moduledoc """
  Table-driven golden runner (VERIFICATION §3.1). `golden_path/1` resolves a
  file under `test/golden/`; `lines/1` reads a syntax vector file (blank lines
  and `#` comments dropped); `assert_bytes_equal/3` fails with the first
  differing byte offset and a hex window around it.
  """
  use Boundary, top_level?: true, deps: []
  use ExUnit.CaseTemplate

  @golden Path.expand("../golden", __DIR__)

  using do
    quote do
      import Aerox.GoldenCase
    end
  end

  def golden_path(rel), do: Path.join(@golden, rel)

  def read_golden!(rel), do: File.read!(golden_path(rel))

  def json_golden!(rel), do: rel |> read_golden!() |> Jason.decode!()

  def lines(rel) do
    rel
    |> read_golden!()
    |> String.split("\n")
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  def assert_bytes_equal(actual, expected, label \\ "bytes") do
    if actual != expected do
      offset = first_diff(actual, expected, 0)

      ExUnit.Assertions.flunk("""
      #{label}: bytes differ at offset #{offset} (actual #{byte_size(actual)} bytes, expected #{byte_size(expected)} bytes)
        actual:   #{hex_window(actual, offset)}
        expected: #{hex_window(expected, offset)}
      """)
    end

    true
  end

  defp first_diff(<<a, ra::binary>>, <<b, rb::binary>>, i) do
    if a == b, do: first_diff(ra, rb, i + 1), else: i
  end

  defp first_diff(_, _, i), do: i

  defp hex_window(bin, offset) do
    start = max(offset - 8, 0)
    len = min(24, byte_size(bin) - start)

    if len > 0 do
      "…#{start}: " <> (binary_part(bin, start, len) |> Base.encode16(case: :lower))
    else
      "<end>"
    end
  end
end
