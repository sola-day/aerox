defmodule Aerox.ATProto.Base58 do
  @moduledoc "base58btc, the multibase `z` encoding used by `did:key` and multikeys."

  @alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  @index Map.new(Enum.with_index(@alphabet))

  @spec encode(binary) :: String.t()
  def encode(bytes) do
    zeros = bytes |> :binary.bin_to_list() |> Enum.take_while(&(&1 == 0)) |> length()

    digits =
      case :binary.decode_unsigned(bytes) do
        0 -> []
        n -> n |> Integer.digits(58) |> Enum.map(&Enum.at(@alphabet, &1))
      end

    List.to_string(List.duplicate(?1, zeros) ++ digits)
  end

  @spec decode(String.t()) :: {:ok, binary} | {:error, :invalid_base58}
  def decode(str) when is_binary(str) do
    chars = String.to_charlist(str)

    if Enum.all?(chars, &Map.has_key?(@index, &1)) do
      zeros = chars |> Enum.take_while(&(&1 == ?1)) |> length()
      n = Enum.reduce(chars, 0, fn c, acc -> acc * 58 + @index[c] end)
      body = if n == 0, do: <<>>, else: :binary.encode_unsigned(n)
      {:ok, :binary.copy(<<0>>, zeros) <> body}
    else
      {:error, :invalid_base58}
    end
  end
end
