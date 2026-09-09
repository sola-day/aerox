defmodule Aerox.ATProto.CARGoldenTest do
  @moduledoc "L2: upstream car-file-fixtures round-trip, and CAR streaming."
  use Aerox.GoldenCase, async: true
  alias Aerox.ATProto.{CAR, CID}

  for {fixture, i} <- Enum.with_index(json_golden!("car/car-file-fixtures.json")) do
    test "fixture #{i}: decode, verify, re-encode" do
      f = unquote(Macro.escape(fixture))
      root = CID.parse!(f["root"])

      blocks =
        Enum.map(f["blocks"], fn %{"cid" => c, "bytes" => b} ->
          {CID.parse!(c), Base.decode64!(b, padding: false)}
        end)

      car = CAR.encode(root, blocks)

      assert {:ok, ^root, decoded} = CAR.decode_with_root(car)
      assert decoded == blocks

      streamed = car |> chunk(7) |> CAR.stream() |> Enum.to_list()
      assert [{:roots, [^root]} | rest] = streamed
      assert Enum.map(rest, fn {:block, c, b} -> {c, b} end) == blocks

      # a corrupted block is caught by CID verification
      [{c, b} | more] = blocks
      bad = CAR.encode(root, [{c, b <> <<0>>} | more])
      assert {:error, {:cid_mismatch, ^c}} = CAR.decode(bad)
    end
  end

  test "varints" do
    for n <- [0, 1, 127, 128, 255, 300, 16_384, 1_000_000, 0xFFFF_FFFF] do
      assert {:ok, ^n, <<>>} = CAR.read_varint(CAR.varint(n))
    end
  end

  test "header errors" do
    assert {:error, _} = CAR.decode(<<>>)
    assert {:error, _} = CAR.decode(<<1, 0xA0>>)
    assert {:error, {:expected_one_root, 0}} = CAR.decode_with_root(CAR.encode(nil, []))
  end

  defp chunk(bin, n) when byte_size(bin) <= n, do: [bin]

  defp chunk(bin, n),
    do: [binary_part(bin, 0, n) | chunk(binary_part(bin, n, byte_size(bin) - n), n)]
end
