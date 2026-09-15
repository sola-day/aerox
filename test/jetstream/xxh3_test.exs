defmodule Aerox.Jetstream.XXH3Test do
  @moduledoc "XXH3-64/128 against zeebo/xxh3's C-compat vectors, lengths 0..4095 (every code path)."
  use Aerox.GoldenCase, async: true
  alias Aerox.Jetstream.XXH3

  @vectors json_golden!("jetstream/xxh3-vectors.json")

  defp input(n), do: for(i <- 0..(n - 1)//1, into: <<>>, do: <<rem(i + 1, 251)>>)

  test "XXH3-64" do
    for {hex, n} <- Enum.with_index(@vectors["xxh3_64"]) do
      assert XXH3.hash64(input(n)) == String.to_integer(hex, 16), "length #{n}"
    end
  end

  test "XXH3-128" do
    for {%{"hi" => hi, "lo" => lo}, n} <- Enum.with_index(@vectors["xxh3_128"]) do
      assert XXH3.hash128(input(n)) == {String.to_integer(hi, 16), String.to_integer(lo, 16)},
             "length #{n}"
    end
  end
end
