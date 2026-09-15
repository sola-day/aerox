defmodule Aerox.Jetstream.CRC32C do
  @moduledoc "CRC-32C (Castagnoli), as Go's `crc32.Checksum(data, crc32.MakeTable(crc32.Castagnoli))`; gloom's serialization checksum."
  import Bitwise

  @table (for n <- 0..255 do
            Enum.reduce(1..8, n, fn _, c ->
              if (c &&& 1) == 1, do: bxor(c >>> 1, 0x82F63B78), else: c >>> 1
            end)
          end)
         |> List.to_tuple()

  @spec checksum(binary) :: non_neg_integer
  def checksum(data), do: bxor(run(data, 0xFFFFFFFF), 0xFFFFFFFF)

  defp run(<<b, rest::binary>>, crc),
    do: run(rest, bxor(elem(@table, bxor(crc, b) &&& 0xFF), crc >>> 8))

  defp run(<<>>, crc), do: crc
end
