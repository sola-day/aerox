defmodule Aerox.ATProto.Space.LtHash do
  @moduledoc """
  The permissioned repo's set digest (DESIGN §12.2, upstream `space/lthash.ts`):
  a 2048-byte state of 1024 little-endian uint16 lanes; an element is expanded
  with BLAKE3-XOF to 2048 bytes and added or removed lane-wise mod 2¹⁶, so the
  digest is commutative and order-independent. `digest/1` is sha256 of the state.
  Golden: `test/golden/space/lthash.json`.
  """
  @lanes 1024
  @state_bytes @lanes * 2

  @type t :: <<_::16384>>

  @spec new() :: t
  def new, do: <<0::size(@state_bytes * 8)>>

  @spec new(binary) :: t
  def new(<<_::binary-size(@state_bytes)>> = state), do: state

  @doc "BLAKE3-XOF expansion of an element to the lane layout."
  @spec expand(String.t()) :: t
  def expand(element) when is_binary(element), do: B3.hash(element, length: @state_bytes)

  @spec add(t, String.t()) :: t
  def add(state, element), do: combine(state, expand(element), &(&1 + &2))

  @spec remove(t, String.t()) :: t
  def remove(state, element), do: combine(state, expand(element), &(&1 - &2))

  defp combine(state, expansion, fun) do
    for <<a::little-16 <- state>>, reduce: {expansion, <<>>} do
      {<<b::little-16, rest::binary>>, acc} ->
        {rest, <<acc::binary, Integer.mod(fun.(a, b), 65_536)::little-16>>}
    end
    |> elem(1)
  end

  @spec digest(t) :: <<_::256>>
  def digest(state), do: :crypto.hash(:sha256, state)

  @spec to_hex(t) :: String.t()
  def to_hex(state), do: Base.encode16(state, case: :lower)

  @spec from_hex(String.t()) :: t
  def from_hex(hex), do: new(Base.decode16!(hex, case: :mixed))

  @doc "The element string of a record: `collection/rkey:cid` (upstream formatRecordElement)."
  @spec record_element(String.t(), String.t(), map) :: String.t()
  def record_element(collection, rkey, record) do
    cid = record |> Aerox.ATProto.DagCBOR.encode() |> Aerox.ATProto.CID.for_cbor()
    "#{collection}/#{rkey}:#{Aerox.ATProto.CID.to_string(cid)}"
  end
end
