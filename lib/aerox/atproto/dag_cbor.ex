defmodule Aerox.ATProto.DagCBOR do
  @moduledoc """
  Validation layer ① (DESIGN §3.2, §3.3): a strict DAG-CBOR codec over the
  in-memory data model of §3.1. Written in-house because nothing on hex is
  DAG-CBOR. Golden oracle: `@ipld/dag-cbor` (`test/golden/dagcbor/`).

  Encoding is deterministic: shortest integer and length forms, map keys
  sorted by byte length then bytewise, CIDs as tag 42 over `0x00 ‖ cid`.
  Decoding is strict and rejects every non-canonical form: non-shortest
  ints or lengths, unsorted or duplicate keys, non-string keys, indefinite
  lengths, floats, undefined, tags other than 42, a tag 42 whose payload is
  not `0x00`-prefixed, invalid UTF-8 text, and trailing bytes.

  Integers span the CBOR 64-bit range here; the narrower atproto data-model
  range is layer ②'s job (`Aerox.ATProto.Data`).
  """
  alias Aerox.ATProto.{Bytes, CID}

  @type value ::
          nil
          | boolean
          | integer
          | String.t()
          | Bytes.t()
          | CID.t()
          | [value]
          | %{optional(String.t()) => value}

  @type decode_error ::
          {:error,
           :non_canonical_int
           | :non_canonical_length
           | :unsorted_keys
           | :duplicate_key
           | :non_string_key
           | :indefinite_length
           | :float_not_allowed
           | :undefined_not_allowed
           | :invalid_utf8
           | :trailing_bytes
           | :truncated
           | :integer_out_of_range
           | {:unsupported_tag, non_neg_integer}
           | {:invalid_cid, term}
           | {:unsupported_simple, non_neg_integer}
           | {:invalid_value, term}}

  @max_u64 0xFFFFFFFFFFFFFFFF

  # ---------------------------------------------------------------- encode

  @doc "Encodes a data-model value to canonical DAG-CBOR bytes."
  @spec encode(value) :: binary
  def encode(value), do: value |> encode_iodata() |> IO.iodata_to_binary()

  @doc "Encodes to iodata (for streaming writers such as CAR)."
  @spec encode_iodata(value) :: iodata
  def encode_iodata(nil), do: <<0xF6>>
  def encode_iodata(false), do: <<0xF4>>
  def encode_iodata(true), do: <<0xF5>>

  def encode_iodata(int) when is_integer(int) and int >= 0 do
    if int > @max_u64, do: raise(ArgumentError, "integer out of CBOR range: #{int}")
    head(0, int)
  end

  def encode_iodata(int) when is_integer(int) do
    n = -1 - int
    if n > @max_u64, do: raise(ArgumentError, "integer out of CBOR range: #{int}")
    head(1, n)
  end

  def encode_iodata(%Bytes{data: data}), do: [head(2, byte_size(data)), data]

  def encode_iodata(%CID{} = cid) do
    payload = CID.to_tag42_bytes(cid)
    [<<0xD8, 42>>, head(2, byte_size(payload)), payload]
  end

  def encode_iodata(str) when is_binary(str) do
    if String.valid?(str),
      do: [head(3, byte_size(str)), str],
      else: raise(ArgumentError, "text is not valid UTF-8")
  end

  def encode_iodata(list) when is_list(list),
    do: [head(4, length(list)) | Enum.map(list, &encode_iodata/1)]

  def encode_iodata(map) when is_map(map) and not is_struct(map) do
    entries =
      map
      |> Enum.map(fn
        {k, v} when is_binary(k) -> {k, v}
        {k, _} -> raise ArgumentError, "map keys must be strings, got #{inspect(k)}"
      end)
      |> Enum.sort_by(fn {k, _} -> {byte_size(k), k} end)

    [
      head(5, map_size(map))
      | Enum.map(entries, fn {k, v} -> [encode_iodata(k), encode_iodata(v)] end)
    ]
  end

  def encode_iodata(other), do: raise(ArgumentError, "not a data-model value: #{inspect(other)}")

  defp head(major, n) when n < 24, do: <<major::3, n::5>>
  defp head(major, n) when n < 0x100, do: <<major::3, 24::5, n>>
  defp head(major, n) when n < 0x10000, do: <<major::3, 25::5, n::16>>
  defp head(major, n) when n < 0x100000000, do: <<major::3, 26::5, n::32>>
  defp head(major, n), do: <<major::3, 27::5, n::64>>

  # ---------------------------------------------------------------- decode

  @doc "Strictly decodes one DAG-CBOR value; any trailing byte is an error."
  @spec decode(binary) :: {:ok, value} | decode_error
  def decode(bytes) when is_binary(bytes) do
    case decode_value(bytes) do
      {:ok, value, <<>>} -> {:ok, value}
      {:ok, _value, _rest} -> {:error, :trailing_bytes}
      {:error, _} = e -> e
    end
  end

  @spec decode!(binary) :: value
  def decode!(bytes) do
    case decode(bytes) do
      {:ok, v} -> v
      {:error, reason} -> raise ArgumentError, "invalid DAG-CBOR: #{inspect(reason)}"
    end
  end

  @doc "Decodes a value and returns what follows it — for CAR-style concatenations."
  @spec decode_prefix(binary) :: {:ok, value, binary} | decode_error
  def decode_prefix(bytes), do: decode_value(bytes)

  @doc "Decodes and returns the CID of the bytes too."
  @spec decode_with_cid(binary) :: {:ok, value, CID.t()} | decode_error
  def decode_with_cid(bytes) do
    with {:ok, v} <- decode(bytes), do: {:ok, v, CID.for_cbor(bytes)}
  end

  defp decode_value(<<major::3, info::5, rest::binary>>) do
    with {:ok, arg, rest} <- argument(major, info, rest) do
      case major do
        0 -> {:ok, arg, rest}
        1 -> {:ok, -1 - arg, rest}
        2 -> take_bytes(arg, rest, &{:ok, Bytes.new(&1), &2})
        3 -> take_text(arg, rest)
        4 -> decode_array(arg, rest, [])
        5 -> decode_map(arg, rest, nil, %{})
        6 -> decode_tag(arg, rest)
        7 -> simple(info, arg, rest)
      end
    end
  end

  defp decode_value(<<>>), do: {:error, :truncated}

  # Major-type argument with the shortest-form check. For major 7 the info
  # byte is the simple value itself, so no minimality rule applies there.
  defp argument(7, info, rest), do: {:ok, info, rest}
  defp argument(_major, info, rest) when info < 24, do: {:ok, info, rest}
  defp argument(_major, 24, <<n, rest::binary>>), do: minimal(n, 24, rest)
  defp argument(_major, 25, <<n::16, rest::binary>>), do: minimal(n, 0x100, rest)
  defp argument(_major, 26, <<n::32, rest::binary>>), do: minimal(n, 0x10000, rest)
  defp argument(_major, 27, <<n::64, rest::binary>>), do: minimal(n, 0x100000000, rest)
  defp argument(_major, 31, _rest), do: {:error, :indefinite_length}

  defp argument(_major, info, _rest) when info in 28..30,
    do: {:error, {:invalid_value, {:reserved_info, info}}}

  defp argument(_major, _info, _rest), do: {:error, :truncated}

  defp minimal(n, min, rest) when n >= min, do: {:ok, n, rest}
  defp minimal(_n, _min, _rest), do: {:error, :non_canonical_int}

  defp take_bytes(len, rest, k) do
    case rest do
      <<data::binary-size(^len), rest::binary>> -> k.(data, rest)
      _ -> {:error, :truncated}
    end
  end

  defp take_text(len, rest) do
    take_bytes(len, rest, fn data, rest ->
      if String.valid?(data), do: {:ok, data, rest}, else: {:error, :invalid_utf8}
    end)
  end

  defp decode_array(0, rest, acc), do: {:ok, Enum.reverse(acc), rest}

  defp decode_array(n, rest, acc) do
    with {:ok, v, rest} <- decode_value(rest), do: decode_array(n - 1, rest, [v | acc])
  end

  defp decode_map(0, rest, _prev, acc), do: {:ok, acc, rest}

  defp decode_map(n, rest, prev, acc) do
    with {:ok, key, rest} <- decode_key(rest),
         :ok <- key_order(prev, key),
         {:ok, v, rest} <- decode_value(rest) do
      decode_map(n - 1, rest, key, Map.put(acc, key, v))
    end
  end

  defp decode_key(<<3::3, info::5, rest::binary>>) do
    with {:ok, len, rest} <- argument(3, info, rest), do: take_text(len, rest)
  end

  defp decode_key(<<>>), do: {:error, :truncated}
  defp decode_key(_), do: {:error, :non_string_key}

  defp key_order(nil, _key), do: :ok

  defp key_order(prev, key) do
    cond do
      prev == key -> {:error, :duplicate_key}
      {byte_size(prev), prev} < {byte_size(key), key} -> :ok
      true -> {:error, :unsorted_keys}
    end
  end

  defp decode_tag(42, <<2::3, info::5, rest::binary>>) do
    with {:ok, len, rest} <- argument(2, info, rest) do
      take_bytes(len, rest, fn payload, rest ->
        case CID.from_tag42_bytes(payload) do
          {:ok, cid} -> {:ok, cid, rest}
          {:error, reason} -> {:error, {:invalid_cid, reason}}
        end
      end)
    end
  end

  defp decode_tag(42, <<>>), do: {:error, :truncated}
  defp decode_tag(42, _), do: {:error, {:invalid_cid, :payload_not_bytes}}
  defp decode_tag(tag, _), do: {:error, {:unsupported_tag, tag}}

  defp simple(20, _, rest), do: {:ok, false, rest}
  defp simple(21, _, rest), do: {:ok, true, rest}
  defp simple(22, _, rest), do: {:ok, nil, rest}
  defp simple(23, _, _rest), do: {:error, :undefined_not_allowed}
  defp simple(info, _, _rest) when info in 25..27, do: {:error, :float_not_allowed}
  defp simple(24, _, _rest), do: {:error, {:unsupported_simple, 24}}
  defp simple(31, _, _rest), do: {:error, :indefinite_length}
  defp simple(info, _, _rest), do: {:error, {:unsupported_simple, info}}
end
