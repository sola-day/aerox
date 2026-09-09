defmodule Aerox.ATProto.Lexicon.Schema do
  @moduledoc """
  Lexicon *document* rules (DESIGN §6.2): the shape a schema file must have
  before it can enter a registry, and lex-URI normalisation. Transcribed
  from `packages/lexicon/src/types.ts` (with the `permission-set` and
  `space` kinds from the `permissioned-data` branch) and indigo
  `lexicon/language.go`; pinned by `test/golden/lexicon/lexicon-*.json`.
  """
  alias Aerox.ATProto.Syntax

  @primary ~w(record query procedure subscription permission-set space)
  @field_types ~w(boolean integer string unknown bytes cid-link ref union blob array)
  @all_types @primary ++ ~w(object token) ++ @field_types
  @formats ~w(datetime uri at-uri did handle at-identifier nsid cid language tid record-key space-uri)

  @type doc :: %{String.t() => term}

  @doc "The def kinds that may only appear as `main`."
  def primary_types, do: @primary

  @doc "String formats the validator understands."
  def formats, do: @formats

  @doc "Checks a decoded lexicon document; returns `{:ok, doc}` with every ref made absolute."
  @spec check_doc(term) :: {:ok, doc} | {:error, String.t()}
  def check_doc(%{"lexicon" => 1, "id" => id, "defs" => defs} = doc)
      when is_binary(id) and is_map(defs) do
    with :ok <-
           if(Syntax.valid_nsid?(id),
             do: :ok,
             else: {:error, "lexicon id is not a valid NSID: #{id}"}
           ),
         :ok <- check_defs(id, defs) do
      {:ok,
       Map.put(doc, "defs", Map.new(defs, fn {name, def} -> {name, resolve_refs(def, id)} end))}
    end
  end

  def check_doc(%{"lexicon" => v}) when v != 1, do: {:error, "lexicon version must be 1"}
  def check_doc(%{"id" => id}) when not is_binary(id), do: {:error, "lexicon id must be a string"}
  def check_doc(_), do: {:error, "lexicon document must have lexicon, id and defs"}

  defp check_defs(id, defs) do
    Enum.find_value(defs, :ok, fn {name, def} ->
      case check_def(name, def) do
        :ok -> nil
        {:error, msg} -> {:error, "#{id}##{name}: #{msg}"}
      end
    end)
  end

  defp check_def(_name, %{"type" => type}) when type not in @all_types,
    do: {:error, "unknown def type #{type}"}

  defp check_def(name, %{"type" => type}) when type in @primary and name != "main",
    do: {:error, "#{type} defs must be the main definition"}

  defp check_def(_name, %{"type" => "unknown"}), do: {:error, "unknown cannot be a top-level def"}
  defp check_def(_name, %{"type" => "ref"}), do: {:error, "ref cannot be a top-level def"}

  defp check_def(_name, %{"type" => "record"} = def) do
    case def["record"] do
      %{"type" => "object"} = obj -> check_object(obj)
      _ -> {:error, "record must contain an object schema"}
    end
  end

  defp check_def(_name, %{"type" => "object"} = def), do: check_object(def)
  defp check_def(_name, %{"type" => "string"} = def), do: check_string(def)

  defp check_def(_name, %{"type" => "permission-set", "permissions" => perms})
       when is_list(perms), do: :ok

  defp check_def(_name, %{"type" => "permission-set"}),
    do: {:error, "permission-set needs permissions"}

  defp check_def(_name, %{"type" => "space", "name" => n, "collections" => c})
       when is_binary(n) and is_list(c), do: :ok

  defp check_def(_name, %{"type" => "space"}), do: {:error, "space needs name and collections"}
  defp check_def(_name, %{"type" => _}), do: :ok
  defp check_def(_name, _), do: {:error, "def has no type"}

  defp check_object(%{"properties" => props} = obj) when is_map(props) do
    required = Map.get(obj, "required", [])

    case Enum.find(required, &(not Map.has_key?(props, &1))) do
      nil -> Enum.find_value(props, :ok, fn {_k, p} -> reject(check_field(p)) end)
      missing -> {:error, "required field #{inspect(missing)} not defined"}
    end
  end

  defp check_object(%{"required" => [_ | _]}),
    do: {:error, "required fields defined but no properties defined"}

  defp check_object(_), do: :ok

  defp check_field(%{"type" => "string"} = f), do: check_string(f)
  defp check_field(%{"type" => "array", "items" => items}), do: check_field(items)
  defp check_field(%{"type" => "array"}), do: {:error, "array needs items"}
  defp check_field(%{"type" => "ref", "ref" => r}) when is_binary(r) and r != "", do: :ok
  defp check_field(%{"type" => "ref"}), do: {:error, "empty schema ref"}

  defp check_field(%{"type" => "union", "refs" => refs} = u) when is_list(refs) do
    if refs == [] and u["closed"] == true,
      do: {:error, "closed empty unions are not allowed"},
      else: :ok
  end

  defp check_field(%{"type" => "union"}), do: {:error, "union needs refs"}
  defp check_field(%{"type" => "object"} = o), do: check_object(o)
  defp check_field(%{"type" => t}) when t in @field_types or t in ["object", "token"], do: :ok
  defp check_field(%{"type" => t}), do: {:error, "unknown field type #{t}"}
  defp check_field(_), do: {:error, "field has no type"}

  defp check_string(%{"format" => f}) when f not in @formats,
    do: {:error, "unknown string format: #{f}"}

  defp check_string(_), do: :ok

  defp reject(:ok), do: nil
  defp reject(err), do: err

  # ---------------------------------------------------------------- URIs

  @doc """
  Absolute def reference for a `ref` string: `#frag` → `<base>#frag`,
  `nsid` → `nsid#main`, `nsid#frag` unchanged, `lex:` prefix dropped.
  """
  @spec to_uri(String.t(), String.t() | nil) :: String.t()
  def to_uri("lex:" <> rest, base), do: to_uri(rest, base)
  def to_uri("#" <> frag, base) when is_binary(base), do: base <> "#" <> frag

  def to_uri("#" <> _, nil),
    do: raise(ArgumentError, "unable to resolve fragment ref without a base")

  def to_uri(ref, _base) do
    case String.split(ref, "#") do
      [nsid] -> nsid <> "#main"
      [_nsid, _frag] -> ref
      _ -> raise ArgumentError, "ref can only have one hash segment: #{ref}"
    end
  end

  @doc "The `$type` string a def is addressed by in data: `nsid` for `main`, else `nsid#name`."
  @spec type_name(String.t()) :: String.t()
  def type_name(uri) do
    case String.split(uri, "#") do
      [nsid, "main"] -> nsid
      _ -> uri
    end
  end

  # Walk a def and make every `ref` / union `refs` absolute.
  defp resolve_refs(%{"type" => "ref", "ref" => r} = def, base),
    do: %{def | "ref" => to_uri(r, base)}

  defp resolve_refs(%{"type" => "union", "refs" => refs} = def, base),
    do: %{def | "refs" => Enum.map(refs, &to_uri(&1, base))}

  defp resolve_refs(%{} = map, base) do
    Map.new(map, fn
      {k, v} when k in ["properties"] and is_map(v) ->
        {k, Map.new(v, fn {pk, pv} -> {pk, resolve_refs(pv, base)} end)}

      {k, v}
      when k in ["items", "record", "schema", "input", "output", "message", "parameters"] and
             is_map(v) ->
        {k, resolve_refs(v, base)}

      {k, v} ->
        {k, v}
    end)
  end

  defp resolve_refs(other, _base), do: other
end
