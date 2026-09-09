defmodule Aerox.ATProto.Data do
  @moduledoc """
  Validation layer ② and the two JSON⇄model codecs (DESIGN §3.1, §3.2).

  The in-memory model is the one `DagCBOR` produces: string-keyed maps,
  lists, integers, booleans, `nil`, text binaries, `%Bytes{}` and `%CID{}`.
  In JSON a CID is `{"$link": "b…"}` and bytes are `{"$bytes": "<base64>"}`;
  a blob reference is an ordinary map `{"$type": "blob", "ref": <cid>,
  "mimeType", "size"}` and is *validated* here, not wrapped (§6.5).

  Rules follow indigo `atproto/atdata` (the oracle for boundary values,
  `test/golden/data-model/`): no floats (a JSON `123.0` is admitted as the
  integer 123, as indigo's `parseFloat` does), integers within the signed
  64-bit range, `$type` a non-empty string when present, `$link`/`$bytes`
  objects with exactly one field, blobs with exactly four, legacy blobs
  `{cid, mimeType}` accepted on read, container and key length limits.
  """
  alias Aerox.ATProto.{Bytes, CID, DagCBOR}

  @max_container_len 128 * 1024
  @max_object_key_len 8192
  @max_string_len 1024 * 1024
  @max_bytes_len 1024 * 1024
  @default_max_depth 128
  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807

  @type error :: {:error, {String.t(), path :: [String.t() | non_neg_integer]}}

  # -------------------------------------------------------------- validate

  @doc """
  Checks a model value against the atproto data model. Returns `:ok` or
  `{:error, {message, path}}` with a JSON-pointer-style path to the offending
  value. Options: `max_depth:` (default #{@default_max_depth}; indigo declares
  32 but does not enforce it).
  """
  @spec validate(term, keyword) :: :ok | error
  def validate(value, opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, @default_max_depth)

    case walk(value, [], 0, max_depth) do
      :ok -> :ok
      {:error, _} = e -> e
    end
  end

  @doc "A record must be a map with a non-empty `$type`."
  @spec validate_record(term, keyword) :: :ok | error
  def validate_record(%{"$type" => type} = record, opts) when is_binary(type) and type != "",
    do: validate(record, opts)

  def validate_record(%{} = _record, _opts),
    do: {:error, {"record $type must be a non-empty string", []}}

  def validate_record(_, _opts), do: {:error, {"record must be an object", []}}

  defp walk(_v, path, depth, max_depth) when depth > max_depth, do: fail("nesting too deep", path)
  defp walk(nil, _p, _d, _m), do: :ok
  defp walk(b, _p, _d, _m) when is_boolean(b), do: :ok

  defp walk(i, path, _d, _m) when is_integer(i) do
    if i >= @int64_min and i <= @int64_max, do: :ok, else: fail("integer out of range", path)
  end

  defp walk(f, path, _d, _m) when is_float(f), do: fail("floats are not allowed", path)

  defp walk(s, path, _d, _m) when is_binary(s),
    do: check_len(byte_size(s), @max_string_len, "string too long", path)

  defp walk(%Bytes{data: d}, path, _d, _m),
    do: check_len(byte_size(d), @max_bytes_len, "bytes too long", path)

  defp walk(%CID{}, _p, _d, _m), do: :ok

  defp walk(list, path, depth, max_depth) when is_list(list) do
    with :ok <- check_len(length(list), @max_container_len, "array too long", path) do
      list
      |> Enum.with_index()
      |> Enum.find_value(:ok, fn {v, i} -> reject(walk(v, [i | path], depth + 1, max_depth)) end)
    end
  end

  defp walk(%{} = map, path, depth, max_depth) when not is_struct(map) do
    with :ok <- check_len(map_size(map), @max_container_len, "object has too many fields", path),
         :ok <- check_type(map, path),
         :ok <- check_blob(map, path) do
      Enum.find_value(map, :ok, fn
        {k, _v} when not is_binary(k) ->
          {:error, {"object keys must be strings", path}}

        {k, _v} when byte_size(k) > @max_object_key_len ->
          {:error, {"object key too long", [k | path]}}

        {k, v} ->
          reject(walk(v, [k | path], depth + 1, max_depth))
      end)
    end
  end

  defp walk(other, path, _d, _m), do: fail("not a data-model value: #{inspect(other)}", path)

  defp reject(:ok), do: nil
  defp reject(err), do: err

  defp check_len(n, max, _msg, _path) when n <= max, do: :ok
  defp check_len(_n, _max, msg, path), do: fail(msg, path)

  defp check_type(%{"$type" => t}, _path) when is_binary(t) and t != "", do: :ok

  defp check_type(%{"$type" => _}, path),
    do: fail("$type field must contain a non-empty string", ["$type" | path])

  defp check_type(_, _), do: :ok

  defp check_blob(%{"$type" => "blob"} = blob, path) do
    cond do
      map_size(blob) != 4 ->
        fail("blobs expected to have 4 fields", path)

      not match?(%CID{}, blob["ref"]) ->
        fail("blob 'ref' missing or not a CID link", ["ref" | path])

      not is_binary(blob["mimeType"]) ->
        fail("blob 'mimeType' missing or not a string", ["mimeType" | path])

      not is_integer(blob["size"]) ->
        fail("blob 'size' missing or not a number", ["size" | path])

      true ->
        :ok
    end
  end

  defp check_blob(_, _), do: :ok

  defp fail(msg, path), do: {:error, {msg, Enum.reverse(path)}}

  # ------------------------------------------------------------ JSON codec

  @doc """
  JSON (already decoded by `Jason`, with string keys) → model. Converts
  `$link`/`$bytes` objects, admits integer-valued floats, rejects real
  floats and malformed link/bytes/blob objects, and validates the result.
  """
  @spec from_json(term, keyword) :: {:ok, DagCBOR.value()} | error
  def from_json(json, opts \\ []) do
    with {:ok, value} <- convert(json, []),
         :ok <- validate(value, opts) do
      {:ok, value}
    end
  end

  @spec from_json!(term, keyword) :: DagCBOR.value()
  def from_json!(json, opts \\ []) do
    case from_json(json, opts) do
      {:ok, v} ->
        v

      {:error, {msg, path}} ->
        raise ArgumentError, "invalid atproto data at /#{Enum.join(path, "/")}: #{msg}"
    end
  end

  @doc "Parses a JSON string straight into the model."
  @spec decode_json(binary, keyword) :: {:ok, DagCBOR.value()} | error
  def decode_json(text, opts \\ []) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, json} -> from_json(json, opts)
      {:error, _} -> {:error, {"invalid JSON", []}}
    end
  end

  defp convert(nil, _), do: {:ok, nil}
  defp convert(b, _) when is_boolean(b), do: {:ok, b}
  defp convert(i, _) when is_integer(i), do: {:ok, i}

  defp convert(f, path) when is_float(f) do
    if f == Float.floor(f) and abs(f) <= 9_007_199_254_740_991.0,
      do: {:ok, trunc(f)},
      else: fail("number is not a safe integer", path)
  end

  defp convert(s, _) when is_binary(s), do: {:ok, s}

  defp convert(list, path) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {v, i}, {:ok, acc} ->
      case convert(v, [i | path]) do
        {:ok, c} -> {:cont, {:ok, [c | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp convert(%{"$link" => _} = obj, path) do
    with :ok <- single_field(obj, "$link", path),
         link when is_binary(link) <-
           obj["$link"] || fail("$link field missing or not a string", path),
         {:ok, cid} <- parse_link(link, path) do
      {:ok, cid}
    else
      {:error, _} = e -> e
      _ -> fail("$link field missing or not a string", ["$link" | path])
    end
  end

  defp convert(%{"$bytes" => _} = obj, path) do
    with :ok <- single_field(obj, "$bytes", path),
         b64 when is_binary(b64) <-
           obj["$bytes"] || fail("$bytes field missing or not a string", path),
         {:ok, bytes} <- decode_bytes(b64, path) do
      {:ok, bytes}
    else
      {:error, _} = e -> e
      _ -> fail("$bytes field missing or not a string", ["$bytes" | path])
    end
  end

  # Legacy blob {cid, mimeType}: accepted on read, normalised to the typed form
  # (DESIGN §6.0 fact 3, §6.6). Size -1 marks it as unknown, as upstream does.
  defp convert(%{"cid" => cid, "mimeType" => mime} = obj, path) when map_size(obj) == 2 do
    with {:ok, cid} <- parse_link(cid, ["cid" | path]) do
      if is_binary(mime),
        do: {:ok, %{"$type" => "blob", "ref" => cid, "mimeType" => mime, "size" => -1}},
        else: fail("legacy blob 'mimeType' not a string", ["mimeType" | path])
    end
  end

  defp convert(%{} = map, path) do
    Enum.reduce_while(map, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      if is_binary(k) do
        case convert(v, [k | path]) do
          {:ok, c} -> {:cont, {:ok, Map.put(acc, k, c)}}
          err -> {:halt, err}
        end
      else
        {:halt, fail("object keys must be strings", path)}
      end
    end)
  end

  defp convert(other, path), do: fail("unexpected JSON value: #{inspect(other)}", path)

  defp single_field(obj, field, path) do
    if map_size(obj) == 1, do: :ok, else: fail("#{field} objects must have a single field", path)
  end

  defp parse_link(link, path) when is_binary(link) do
    case CID.parse(link) do
      {:ok, cid} -> {:ok, cid}
      {:error, reason} -> fail("invalid $link CID: #{inspect(reason)}", path)
    end
  end

  defp parse_link(_, path), do: fail("$link field missing or not a string", path)

  defp decode_bytes(b64, path) do
    case Bytes.from_base64(b64) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> fail("decoding $bytes value: invalid base64", path)
    end
  end

  @doc "Model → JSON-ready term (string-keyed maps, `$link`/`$bytes` objects)."
  @spec to_json(DagCBOR.value()) :: term
  def to_json(nil), do: nil
  def to_json(b) when is_boolean(b), do: b
  def to_json(i) when is_integer(i), do: i
  def to_json(s) when is_binary(s), do: s
  def to_json(%CID{} = cid), do: %{"$link" => CID.to_string(cid)}
  def to_json(%Bytes{} = bytes), do: %{"$bytes" => Bytes.to_base64(bytes)}
  def to_json(list) when is_list(list), do: Enum.map(list, &to_json/1)
  def to_json(%{} = map), do: Map.new(map, fn {k, v} -> {k, to_json(v)} end)

  @doc "Model → JSON text."
  @spec encode_json(DagCBOR.value()) :: binary
  def encode_json(value), do: value |> to_json() |> Jason.encode!()

  # ---------------------------------------------------------------- CBOR

  @doc "Strict CBOR decode followed by data-model validation — what a PDS or Relay runs on incoming blocks."
  @spec decode_cbor(binary, keyword) :: {:ok, DagCBOR.value()} | error | DagCBOR.decode_error()
  def decode_cbor(bytes, opts \\ []) do
    with {:ok, value} <- DagCBOR.decode(bytes),
         :ok <- validate(value, opts) do
      {:ok, value}
    end
  end

  @doc "Validates then encodes; the CID is computed from the bytes."
  @spec encode_cbor(DagCBOR.value(), keyword) :: {:ok, binary, CID.t()} | error
  def encode_cbor(value, opts \\ []) do
    with :ok <- validate(value, opts) do
      bytes = DagCBOR.encode(value)
      {:ok, bytes, CID.for_cbor(bytes)}
    end
  end

  @doc "Extracts every blob reference in a value, in traversal order."
  @spec blob_refs(DagCBOR.value()) :: [map]
  def blob_refs(value), do: value |> collect_blobs([]) |> Enum.reverse()

  defp collect_blobs(%{"$type" => "blob", "ref" => %CID{}} = blob, acc), do: [blob | acc]

  defp collect_blobs(%{} = map, acc) when not is_struct(map),
    do: Enum.reduce(map, acc, fn {_k, v}, a -> collect_blobs(v, a) end)

  defp collect_blobs(list, acc) when is_list(list), do: Enum.reduce(list, acc, &collect_blobs/2)
  defp collect_blobs(_, acc), do: acc
end
