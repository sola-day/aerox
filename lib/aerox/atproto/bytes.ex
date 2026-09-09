defmodule Aerox.ATProto.Bytes do
  @moduledoc """
  The only wrapper type in the data model (DESIGN §3.1). An Elixir binary is
  both text and bytes; CBOR major types 2 and 3 are not. Text stays a plain
  binary because it is everywhere; bytes — a commit's `sig`, an MST node's
  `k`, JSON `$bytes` — are wrapped so the codecs can tell them apart.
  """
  @enforce_keys [:data]
  defstruct [:data]

  @type t :: %__MODULE__{data: binary}

  @spec new(binary) :: t
  def new(data) when is_binary(data), do: %__MODULE__{data: data}

  @doc "Unpadded standard base64, the JSON `$bytes` form."
  @spec to_base64(t) :: String.t()
  def to_base64(%__MODULE__{data: data}), do: Base.encode64(data, padding: false)

  @doc "Accepts padded or unpadded standard base64, as upstream's `fromBase64` does."
  @spec from_base64(String.t()) :: {:ok, t} | :error
  def from_base64(str) when is_binary(str) do
    case Base.decode64(String.trim_trailing(str, "="), padding: false) do
      {:ok, data} -> {:ok, new(data)}
      :error -> :error
    end
  end

  defimpl Inspect do
    def inspect(%{data: data}, _opts) do
      "#Bytes<#{byte_size(data)}:#{Base.encode16(binary_part(data, 0, min(8, byte_size(data))), case: :lower)}#{if byte_size(data) > 8, do: "…", else: ""}>"
    end
  end
end
