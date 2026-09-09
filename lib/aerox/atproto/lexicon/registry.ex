defmodule Aerox.ATProto.Lexicon.Registry do
  @moduledoc """
  A set of lexicon documents with every def addressable by absolute URI
  (`nsid#name`), passed *explicitly* to the validator (DESIGN §6.3) — the
  same pattern as the MST's blockstore. `Aerox.ATProto.Lexicon.Vendored`
  builds the compile-time default from `priv/lexicons/`; documents obtained
  later (`resolveLexicon`, `app.bsky.*` added per endpoint) are merged in
  outside the kernel with `add/2`.
  """
  alias Aerox.ATProto.Lexicon.Schema

  defstruct docs: %{}, defs: %{}

  @type t :: %__MODULE__{docs: %{String.t() => Schema.doc()}, defs: %{String.t() => map}}

  @spec new([map]) :: {:ok, t} | {:error, term}
  def new(docs \\ []) do
    Enum.reduce_while(docs, {:ok, %__MODULE__{}}, fn doc, {:ok, reg} ->
      case add(reg, doc) do
        {:ok, reg} -> {:cont, {:ok, reg}}
        e -> {:halt, e}
      end
    end)
  end

  @spec new!([map]) :: t
  def new!(docs) do
    case new(docs) do
      {:ok, reg} -> reg
      {:error, reason} -> raise ArgumentError, "invalid lexicon: #{inspect(reason)}"
    end
  end

  @doc "Adds a document (checked); a second document with the same id is an error."
  @spec add(t, map) :: {:ok, t} | {:error, term}
  def add(%__MODULE__{} = reg, doc) do
    with {:ok, %{"id" => id, "defs" => defs} = doc} <- Schema.check_doc(doc) do
      if Map.has_key?(reg.docs, id) do
        {:error, "#{id} has already been registered"}
      else
        defs = Map.new(defs, fn {name, def} -> {id <> "#" <> name, def} end)
        {:ok, %{reg | docs: Map.put(reg.docs, id, doc), defs: Map.merge(reg.defs, defs)}}
      end
    end
  end

  @doc "Merges `extra` over `base`; documents in `extra` replace same-id documents in `base`."
  @spec merge(t, t) :: t
  def merge(%__MODULE__{} = base, %__MODULE__{} = extra) do
    replaced = Map.keys(extra.docs)

    base_defs =
      base.defs
      |> Enum.reject(fn {uri, _} -> hd(String.split(uri, "#")) in replaced end)
      |> Map.new()

    %__MODULE__{docs: Map.merge(base.docs, extra.docs), defs: Map.merge(base_defs, extra.defs)}
  end

  @spec get_doc(t, String.t()) :: map | nil
  def get_doc(%__MODULE__{docs: docs}, nsid), do: Map.get(docs, nsid)

  @doc "A def by ref (`nsid`, `nsid#name`, `#name` is not allowed here)."
  @spec get_def(t, String.t()) :: {:ok, map} | :error
  def get_def(%__MODULE__{defs: defs}, ref), do: Map.fetch(defs, Schema.to_uri(ref, nil))

  @spec known?(t, String.t()) :: boolean
  def known?(reg, ref), do: match?({:ok, _}, get_def(reg, ref))

  @doc "Every def URI whose kind is `type`."
  @spec defs_of_type(t, String.t()) :: [String.t()]
  def defs_of_type(%__MODULE__{defs: defs}, type) do
    for {uri, %{"type" => ^type}} <- defs, do: uri
  end

  @doc "NSIDs of documents whose main def is a record."
  @spec record_types(t) :: [String.t()]
  def record_types(reg),
    do: reg |> defs_of_type("record") |> Enum.map(&Schema.type_name/1) |> Enum.sort()

  @doc "Every `ref`/union target that does not resolve — empty for a consistent registry."
  @spec dangling_refs(t) :: [{String.t(), String.t()}]
  def dangling_refs(%__MODULE__{defs: defs} = reg) do
    defs
    |> Enum.flat_map(fn {uri, def} -> collect_refs(def) |> Enum.map(&{uri, &1}) end)
    |> Enum.reject(fn {_from, ref} -> known?(reg, ref) end)
    |> Enum.uniq()
  end

  defp collect_refs(%{"type" => "ref", "ref" => r}), do: [r]
  defp collect_refs(%{"type" => "union", "refs" => refs}), do: refs
  defp collect_refs(%{} = map), do: Enum.flat_map(map, fn {_k, v} -> collect_refs(v) end)
  defp collect_refs(list) when is_list(list), do: Enum.flat_map(list, &collect_refs/1)
  defp collect_refs(_), do: []
end
