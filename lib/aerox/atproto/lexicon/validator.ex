defmodule Aerox.ATProto.Lexicon.Validator do
  @moduledoc """
  The runtime interpreter (DESIGN §6.2): walks a def and a model value.
  Transcribed from `packages/lexicon/src/validators/*.ts`, with the checks
  indigo `lexicon/language.go` adds where the two differ on the strict side
  (blob `accept`/`maxSize`, `unknown` must be an object). Errors carry a
  JSON-pointer-style path (DESIGN §6.6).

  Values are the §3.1 model: string-keyed maps, `%CID{}`, `%Bytes{}`, and a
  blob is the map `{$type: "blob", ref, mimeType, size}` the `Data` layer
  already validated.
  """
  alias Aerox.ATProto.{Bytes, CID, Syntax}
  alias Aerox.ATProto.Lexicon.{Registry, Schema}

  @type path :: [String.t() | non_neg_integer]
  @type result :: {:ok, term} | {:error, {String.t(), path}}

  @doc "Validates `value` against the def at `ref`, filling primitive defaults."
  @spec validate(Registry.t(), String.t(), term, path) :: result
  def validate(reg, ref, value, path \\ []) do
    case Registry.get_def(reg, ref) do
      {:ok, def} -> validate_def(reg, def, value, path)
      :error -> {:error, {"Lexicon not found: #{ref}", path}}
    end
  end

  @doc "A record: its `$type` must name the schema; then the `record` object."
  @spec validate_record(Registry.t(), String.t(), term) :: result
  def validate_record(reg, nsid, %{"$type" => type} = record) when is_binary(type) do
    with {:ok, %{"type" => "record", "record" => obj}} <- fetch(reg, nsid, ["record"]),
         :ok <-
           if(Schema.type_name(Schema.to_uri(type, nil)) == nsid,
             do: :ok,
             else: {:error, {"record $type must be #{nsid}", ["record", "$type"]}}
           ) do
      object(reg, obj, record, ["record"])
    else
      {:ok, _} -> {:error, {"#{nsid} is not a record lexicon", ["record"]}}
      e -> e
    end
  end

  def validate_record(_reg, _nsid, _),
    do: {:error, {"record must be an object with a $type", ["record"]}}

  @doc "XRPC parameters (query string): only primitives and primitive arrays; missing values take defaults."
  @spec validate_params(Registry.t(), String.t(), map) :: result
  def validate_params(reg, nsid, params) do
    with {:ok, def} <- fetch(reg, nsid, ["params"]) do
      case def["parameters"] do
        nil -> {:ok, params}
        %{"properties" => props} = pdef -> params_object(reg, pdef, props, params || %{})
        _ -> {:ok, params}
      end
    end
  end

  @doc "XRPC input body against `input.schema` (procedures)."
  @spec validate_input(Registry.t(), String.t(), term) :: result
  def validate_input(reg, nsid, value), do: validate_body(reg, nsid, "input", value)

  @doc "XRPC output body against `output.schema`."
  @spec validate_output(Registry.t(), String.t(), term) :: result
  def validate_output(reg, nsid, value), do: validate_body(reg, nsid, "output", value)

  @doc "A subscription message against `message.schema`."
  @spec validate_message(Registry.t(), String.t(), term) :: result
  def validate_message(reg, nsid, value), do: validate_body(reg, nsid, "message", value)

  defp validate_body(reg, nsid, kind, value) do
    with {:ok, def} <- fetch(reg, nsid, [kind]) do
      case get_in(def, [kind, "schema"]) do
        nil -> {:ok, value}
        schema -> one_of(reg, schema, value, [kind], true)
      end
    end
  end

  defp fetch(reg, ref, path) do
    case Registry.get_def(reg, ref) do
      {:ok, def} -> {:ok, def}
      :error -> {:error, {"Lexicon not found: #{ref}", path}}
    end
  end

  # ------------------------------------------------------------ dispatch

  @doc false
  def validate_def(reg, %{"type" => type} = def, value, path) do
    case type do
      "object" -> object(reg, def, value, path)
      "array" -> array(reg, def, value, path)
      "blob" -> blob(def, value, path)
      "boolean" -> boolean(def, value, path)
      "integer" -> integer(def, value, path)
      "string" -> string(def, value, path)
      "bytes" -> bytes(def, value, path)
      "cid-link" -> cid_link(value, path)
      "unknown" -> unknown(value, path)
      "ref" -> one_of(reg, def, value, path, false)
      "union" -> one_of(reg, def, value, path, false)
      "record" -> validate_def(reg, def["record"], value, path)
      "params" -> params_object(reg, def, def["properties"] || %{}, value)
      other -> fail("Unexpected lexicon type: #{other}", path)
    end
  end

  # ref / union resolution (upstream validateOneOf)
  defp one_of(reg, %{"type" => "union", "refs" => refs} = def, value, path, must_be_obj) do
    case value do
      %{"$type" => type} when is_binary(type) ->
        case Enum.find(refs, &type_matches?(&1, type)) do
          nil ->
            if def["closed"] == true,
              do: fail("#{pointer(path)} $type must be one of #{Enum.join(refs, ", ")}", path),
              else: {:ok, value}

          ref ->
            resolve_and_validate(reg, ref, value, path, must_be_obj)
        end

      _ ->
        fail("#{pointer(path)} must be an object which includes the \"$type\" property", path)
    end
  end

  defp one_of(reg, %{"type" => "ref", "ref" => ref}, value, path, must_be_obj),
    do: resolve_and_validate(reg, ref, value, path, must_be_obj)

  defp one_of(reg, def, value, path, true), do: object(reg, def, value, path)
  defp one_of(reg, def, value, path, false), do: validate_def(reg, def, value, path)

  defp resolve_and_validate(reg, ref, value, path, must_be_obj) do
    case Registry.get_def(reg, ref) do
      {:ok, def} when must_be_obj -> object(reg, def, value, path)
      {:ok, def} -> validate_def(reg, def, value, path)
      :error -> fail("Lexicon not found: #{ref}", path)
    end
  end

  # upstream refsContainType: refs are absolute `nsid#name`; a $type of
  # `nsid` means `nsid#main`.
  defp type_matches?(ref, type), do: Schema.to_uri(type, nil) == ref

  # ------------------------------------------------------------- object

  @doc false
  def object(reg, def, value, path) when is_map(value) and not is_struct(value) do
    props = Map.get(def, "properties") || %{}
    required = Map.get(def, "required") || []
    nullable = Map.get(def, "nullable") || []

    Enum.reduce_while(props, {:ok, value}, fn {key, pdef}, {:ok, acc} ->
      prop_path = path ++ [key]

      case Map.fetch(value, key) do
        {:ok, nil} = fetched when is_list(nullable) ->
          if key in nullable do
            {:cont, {:ok, acc}}
          else
            {:ok, v} = fetched
            check_prop(reg, pdef, v, prop_path, key, acc)
          end

        {:ok, v} ->
          case one_of(reg, pdef, v, prop_path, false) do
            {:ok, ^v} -> {:cont, {:ok, acc}}
            {:ok, v2} -> {:cont, {:ok, Map.put(acc, key, v2)}}
            e -> {:halt, e}
          end

        :error ->
          cond do
            key in required ->
              {:halt, fail("#{pointer(path)} must have the property \"#{key}\"", path)}

            default?(pdef) ->
              {:cont, {:ok, Map.put(acc, key, pdef["default"])}}

            true ->
              {:cont, {:ok, acc}}
          end
      end
    end)
  end

  def object(_reg, _def, _value, path), do: fail("#{pointer(path)} must be an object", path)

  defp check_prop(reg, pdef, v, prop_path, key, acc) do
    case one_of(reg, pdef, v, prop_path, false) do
      {:ok, ^v} -> {:cont, {:ok, acc}}
      {:ok, v2} -> {:cont, {:ok, Map.put(acc, key, v2)}}
      e -> {:halt, e}
    end
  end

  defp default?(%{"type" => t, "default" => d})
       when t in ["integer", "boolean", "string"] and not is_nil(d), do: true

  defp default?(_), do: false

  defp params_object(reg, def, props, value) when is_map(value) do
    required = Map.get(def, "required") || []

    Enum.reduce_while(props, {:ok, value}, fn {key, pdef}, {:ok, acc} ->
      case Map.fetch(value, key) do
        {:ok, v} ->
          result =
            if pdef["type"] == "array",
              do: array(reg, pdef, v, [key]),
              else: validate_def(reg, pdef, v, [key])

          case result do
            {:ok, v2} -> {:cont, {:ok, Map.put(acc, key, v2)}}
            e -> {:halt, e}
          end

        :error ->
          cond do
            key in required -> {:halt, fail("Params must have the property \"#{key}\"", [key])}
            default?(pdef) -> {:cont, {:ok, Map.put(acc, key, pdef["default"])}}
            true -> {:cont, {:ok, acc}}
          end
      end
    end)
  end

  defp params_object(_reg, _def, _props, _value), do: fail("Params must be an object", [])

  # -------------------------------------------------------------- array

  defp array(reg, def, value, path) when is_list(value) do
    len = length(value)

    cond do
      is_integer(def["maxLength"]) and len > def["maxLength"] ->
        fail("#{pointer(path)} must not have more than #{def["maxLength"]} elements", path)

      is_integer(def["minLength"]) and len < def["minLength"] ->
        fail("#{pointer(path)} must not have fewer than #{def["minLength"]} elements", path)

      true ->
        value
        |> Enum.with_index()
        |> Enum.reduce_while({:ok, []}, fn {item, i}, {:ok, acc} ->
          case one_of(reg, def["items"], item, path ++ [i], false) do
            {:ok, v} -> {:cont, {:ok, [v | acc]}}
            e -> {:halt, e}
          end
        end)
        |> case do
          {:ok, acc} -> {:ok, Enum.reverse(acc)}
          e -> e
        end
    end
  end

  defp array(_reg, _def, _value, path), do: fail("#{pointer(path)} must be an array", path)

  # --------------------------------------------------------- primitives

  defp boolean(def, value, path) do
    cond do
      not is_boolean(value) ->
        fail("#{pointer(path)} must be a boolean", path)

      is_boolean(def["const"]) and value != def["const"] ->
        fail("#{pointer(path)} must be #{def["const"]}", path)

      true ->
        {:ok, value}
    end
  end

  defp integer(def, value, path) do
    cond do
      not is_integer(value) ->
        fail("#{pointer(path)} must be an integer", path)

      is_integer(def["const"]) and value != def["const"] ->
        fail("#{pointer(path)} must be #{def["const"]}", path)

      is_list(def["enum"]) and value not in def["enum"] ->
        fail("#{pointer(path)} must be one of (#{Enum.join(def["enum"], "|")})", path)

      is_integer(def["maximum"]) and value > def["maximum"] ->
        fail("#{pointer(path)} can not be greater than #{def["maximum"]}", path)

      is_integer(def["minimum"]) and value < def["minimum"] ->
        fail("#{pointer(path)} can not be less than #{def["minimum"]}", path)

      true ->
        {:ok, value}
    end
  end

  defp string(def, value, path) when is_binary(value) do
    cond do
      is_binary(def["const"]) and value != def["const"] ->
        fail("#{pointer(path)} must be #{def["const"]}", path)

      is_list(def["enum"]) and value not in def["enum"] ->
        fail("#{pointer(path)} must be one of (#{Enum.join(def["enum"], "|")})", path)

      is_integer(def["minLength"]) and byte_size(value) < def["minLength"] ->
        fail("#{pointer(path)} must not be shorter than #{def["minLength"]} characters", path)

      is_integer(def["maxLength"]) and byte_size(value) > def["maxLength"] ->
        fail("#{pointer(path)} must not be longer than #{def["maxLength"]} characters", path)

      is_integer(def["minGraphemes"]) and String.length(value) < def["minGraphemes"] ->
        fail("#{pointer(path)} must not be shorter than #{def["minGraphemes"]} graphemes", path)

      is_integer(def["maxGraphemes"]) and String.length(value) > def["maxGraphemes"] ->
        fail("#{pointer(path)} must not be longer than #{def["maxGraphemes"]} graphemes", path)

      is_binary(def["format"]) ->
        format(def["format"], value, path)

      true ->
        {:ok, value}
    end
  end

  defp string(_def, _value, path), do: fail("#{pointer(path)} must be a string", path)

  defp format(fmt, value, path) do
    ok? =
      case fmt do
        "datetime" -> Syntax.valid_datetime?(value)
        "uri" -> Syntax.valid_uri?(value)
        "at-uri" -> Syntax.valid_at_uri?(value)
        "did" -> Syntax.valid_did?(value)
        "handle" -> Syntax.valid_handle?(value)
        "at-identifier" -> Syntax.valid_at_identifier?(value)
        "nsid" -> Syntax.valid_nsid?(value)
        "cid" -> CID.valid?(value)
        "language" -> Syntax.valid_language?(value)
        "tid" -> Syntax.valid_tid?(value)
        "record-key" -> Syntax.valid_record_key?(value)
        "space-uri" -> Syntax.valid_space_uri?(value)
        _ -> true
      end

    if ok?, do: {:ok, value}, else: fail("#{pointer(path)} must be a valid #{fmt}", path)
  end

  defp bytes(def, %Bytes{data: data} = value, path) do
    cond do
      is_integer(def["maxLength"]) and byte_size(data) > def["maxLength"] ->
        fail("#{pointer(path)} must not be larger than #{def["maxLength"]} bytes", path)

      is_integer(def["minLength"]) and byte_size(data) < def["minLength"] ->
        fail("#{pointer(path)} must not be smaller than #{def["minLength"]} bytes", path)

      true ->
        {:ok, value}
    end
  end

  defp bytes(_def, _value, path), do: fail("#{pointer(path)} must be a byte array", path)

  defp cid_link(%CID{} = v, _path), do: {:ok, v}
  defp cid_link(_, path), do: fail("#{pointer(path)} must be a CID", path)

  # indigo: unknown data must be an object; a blob or bytes wrapper is not.
  defp unknown(%{"$type" => "blob"} = v, path) when map_size(v) == 4,
    do: fail("#{pointer(path)} must be an object", path)

  defp unknown(%{} = v, _path) when not is_struct(v), do: {:ok, v}
  defp unknown(_, path), do: fail("#{pointer(path)} must be an object", path)

  defp blob(
         def,
         %{"$type" => "blob", "ref" => %CID{}, "mimeType" => mime, "size" => size} = value,
         path
       )
       when is_binary(mime) and is_integer(size) do
    accept = def["accept"] || []

    cond do
      accept != [] and not Enum.any?(accept, &mime_matches?(&1, mime)) ->
        fail("#{pointer(path)} blob mimetype doesn't match accepted: #{mime}", path)

      is_integer(def["maxSize"]) and size > def["maxSize"] ->
        fail("#{pointer(path)} blob size too large: #{size}", path)

      true ->
        {:ok, value}
    end
  end

  defp blob(_def, _value, path), do: fail("#{pointer(path)} should be a blob ref", path)

  defp mime_matches?("*/*", _), do: true

  defp mime_matches?(pattern, mime) do
    case String.split(pattern, "/") do
      [type, "*"] -> String.starts_with?(mime, type <> "/")
      _ -> pattern == mime
    end
  end

  defp fail(msg, path), do: {:error, {msg, path}}

  defp pointer([]), do: "Record"
  defp pointer(path), do: Enum.map_join(path, "/", &to_string/1)
end
