defmodule Aerox.ATProto.CID do
  @moduledoc """
  CIDv1 with sha-256 (DESIGN §3.4). Only two codecs exist in atproto:
  `dag-cbor` (0x71, records, commits, MST nodes) and `raw` (0x55, blobs).
  String form is base32 lower-case multibase (`b…`); binary form is
  `0x01 <codec> 0x12 0x20 <32-byte digest>`; inside DAG-CBOR it is tag 42
  over `0x00 <binary form>` (the multibase identity prefix — DESIGN §3.3
  point 2, the commonest interop bug).
  """
  alias Aerox.ATProto.Bytes

  @enforce_keys [:codec, :digest]
  defstruct [:codec, :digest]

  @type codec :: :dag_cbor | :raw
  @type t :: %__MODULE__{codec: codec, digest: <<_::256>>}

  @dag_cbor 0x71
  @raw 0x55
  @sha256 0x12

  @doc "The CID of a DAG-CBOR block."
  @spec for_cbor(iodata) :: t
  def for_cbor(bytes), do: %__MODULE__{codec: :dag_cbor, digest: :crypto.hash(:sha256, bytes)}

  @doc "The CID of raw bytes (blobs)."
  @spec for_raw(iodata) :: t
  def for_raw(bytes), do: %__MODULE__{codec: :raw, digest: :crypto.hash(:sha256, bytes)}

  @doc "Multicodec code of the CID's content."
  @spec codec_code(t) :: 0x71 | 0x55
  def codec_code(%__MODULE__{codec: :dag_cbor}), do: @dag_cbor
  def codec_code(%__MODULE__{codec: :raw}), do: @raw

  @doc "Binary form: version, codec, multihash."
  @spec to_bytes(t) :: binary
  def to_bytes(%__MODULE__{digest: digest} = cid),
    do: <<0x01, codec_code(cid), @sha256, 0x20, digest::binary-size(32)>>

  @doc "The bytes carried inside CBOR tag 42: identity multibase prefix plus binary form."
  @spec to_tag42_bytes(t) :: binary
  def to_tag42_bytes(cid), do: <<0x00, to_bytes(cid)::binary>>

  @doc "Parses the binary form (without the tag-42 `0x00` prefix)."
  @spec from_bytes(binary) :: {:ok, t} | {:error, term}
  def from_bytes(<<0x01, codec, @sha256, 0x20, digest::binary-size(32)>>) do
    case codec do
      @dag_cbor -> {:ok, %__MODULE__{codec: :dag_cbor, digest: digest}}
      @raw -> {:ok, %__MODULE__{codec: :raw, digest: digest}}
      other -> {:error, {:unsupported_codec, other}}
    end
  end

  def from_bytes(<<0x01, _codec, hash, _::binary>>) when hash != @sha256,
    do: {:error, {:unsupported_hash, hash}}

  def from_bytes(<<0x12, 0x20, _::binary-size(32)>>), do: {:error, :cidv0_not_supported}
  def from_bytes(_), do: {:error, :malformed_cid}

  @doc "Parses the tag-42 payload: `0x00` then binary form."
  @spec from_tag42_bytes(binary) :: {:ok, t} | {:error, term}
  def from_tag42_bytes(<<0x00, rest::binary>>), do: from_bytes(rest)
  def from_tag42_bytes(_), do: {:error, :missing_identity_prefix}

  @doc "String form: `b` + lower-case base32, no padding."
  @spec to_string(t) :: String.t()
  def to_string(%__MODULE__{} = cid),
    do: "b" <> Base.encode32(to_bytes(cid), case: :lower, padding: false)

  @doc "Parses the base32 multibase string form. Upper-case base32 is accepted, nothing else."
  @spec parse(term) :: {:ok, t} | {:error, term}
  def parse("b" <> rest) when byte_size(rest) > 0 do
    case Base.decode32(rest, case: :mixed, padding: false) do
      {:ok, bytes} -> from_bytes(bytes)
      :error -> {:error, :invalid_base32}
    end
  end

  def parse(str) when is_binary(str), do: {:error, :unsupported_multibase}
  def parse(_), do: {:error, :not_a_string}

  @spec parse!(String.t()) :: t
  def parse!(str) do
    case parse(str) do
      {:ok, cid} -> cid
      {:error, reason} -> raise ArgumentError, "invalid CID #{inspect(str)}: #{inspect(reason)}"
    end
  end

  @spec valid?(term) :: boolean
  def valid?(str), do: match?({:ok, _}, parse(str))

  @doc "True when `bytes` hash to this CID under its codec."
  @spec verify(t, iodata) :: boolean
  def verify(%__MODULE__{digest: digest}, bytes), do: :crypto.hash(:sha256, bytes) == digest

  @doc "The digest as a `Bytes` wrapper, for callers that need it in the data model."
  @spec digest_bytes(t) :: Bytes.t()
  def digest_bytes(%__MODULE__{digest: d}), do: Bytes.new(d)

  defimpl String.Chars do
    def to_string(cid), do: Aerox.ATProto.CID.to_string(cid)
  end

  defimpl Inspect do
    def inspect(cid, _opts), do: "#CID<#{Aerox.ATProto.CID.to_string(cid)}>"
  end
end
