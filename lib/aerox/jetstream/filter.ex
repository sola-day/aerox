defmodule Aerox.Jetstream.Filter do
  @moduledoc """
  Subscriber filters (upstream `internal/subscribe/filter.go`, `filterv2.go`).

  **v1**: `wantedCollections` (NSIDs or `<prefix>.*`, at most 100) and
  `wantedDids` (at most 10,000) — identity and account events pass any
  collection filter; `maxMessageSizeBytes` (bad values coerce to 0); updatable
  with an `options_update` message.

  **v2**: `kinds` (commit, identity, account, sync), `dids`, `collections` —
  independent predicates ANDed, collections constraining commits only; the v1
  names are refused, as is a collections filter that `kinds` makes
  unreachable, and `maxMessageSizeBytes` must be a u32.
  """
  alias Aerox.ATProto.Syntax
  alias Aerox.Jetstream.Event

  @max_collections 100
  @max_dids 10_000

  defstruct kinds: nil, dids: nil, exact: nil, prefixes: [], max_bytes: 0

  @type t :: %__MODULE__{}

  @doc "Query pairs (repeated keys preserved) for a query string."
  def pairs(query_string), do: query_string |> URI.query_decoder() |> Enum.to_list()

  defp values(pairs, key), do: for({k, v} <- pairs, k == key, do: v)
  defp has?(pairs, key), do: Enum.any?(pairs, fn {k, _} -> k == key end)

  # ------------------------------------------------------------------ v1

  @spec v1(list) :: {:ok, t} | {:error, String.t()}
  def v1(pairs) do
    with {:ok, {exact, prefixes}} <- collections(values(pairs, "wantedCollections"), false),
         {:ok, dids} <- dids(values(pairs, "wantedDids")) do
      {:ok,
       %__MODULE__{
         exact: exact,
         prefixes: prefixes,
         dids: dids,
         max_bytes: coerce_size(List.first(values(pairs, "maxMessageSizeBytes")))
       }}
    end
  end

  @doc "An `options_update` payload."
  def v1_update(%{} = payload) do
    with {:ok, {exact, prefixes}} <- collections(List.wrap(payload["wantedCollections"]), false),
         {:ok, dids} <- dids(List.wrap(payload["wantedDids"])) do
      max = payload["maxMessageSizeBytes"]

      {:ok,
       %__MODULE__{
         exact: exact,
         prefixes: prefixes,
         dids: dids,
         max_bytes: if(is_integer(max) and max > 0, do: max, else: 0)
       }}
    end
  end

  def v1_update(_), do: {:error, "invalid options"}

  defp coerce_size(nil), do: 0

  defp coerce_size(s) do
    case Integer.parse(s) do
      {n, ""} when n > 0 and n <= 0xFFFFFFFF -> n
      _ -> 0
    end
  end

  # ------------------------------------------------------------------ v2

  @spec v2(list) :: {:ok, t} | {:error, String.t()}
  def v2(pairs) do
    cond do
      has?(pairs, "wantedDids") ->
        {:error, "wantedDids is the legacy /subscribe parameter; use dids"}

      has?(pairs, "wantedCollections") ->
        {:error, "wantedCollections is the legacy /subscribe parameter; use collections"}

      has?(pairs, "requireHello") ->
        {:error,
         "requireHello is not supported on this endpoint; it is server-push only (subscriber-sourced messages were removed)"}

      length(values(pairs, "kinds")) > 4 ->
        {:error, "too many kinds values: #{length(values(pairs, "kinds"))} > 4"}

      length(values(pairs, "dids")) > @max_dids ->
        {:error, "too many dids values"}

      length(values(pairs, "collections")) > @max_collections ->
        {:error, "too many collections values"}

      true ->
        v2_parse(pairs)
    end
  end

  defp v2_parse(pairs) do
    with {:ok, kinds} <- kinds(values(pairs, "kinds")),
         {:ok, dids} <- dids(values(pairs, "dids")),
         {:ok, {exact, prefixes}} <- collections(values(pairs, "collections"), true),
         :ok <-
           if(exact != nil and kinds != nil and :commit not in kinds,
             do: {:error, "collections filter can never apply: kinds excludes commit"},
             else: :ok
           ),
         {:ok, max} <-
           v2_size(values(pairs, "maxMessageSizeBytes"), has?(pairs, "maxMessageSizeBytes")) do
      {:ok,
       %__MODULE__{kinds: kinds, dids: dids, exact: exact, prefixes: prefixes, max_bytes: max}}
    end
  end

  defp v2_size(_, false), do: {:ok, 0}

  defp v2_size([v], true) when v != "" do
    case Integer.parse(v) do
      {n, ""} when n >= 0 and n <= 0xFFFFFFFF -> {:ok, n}
      _ -> {:error, "invalid maxMessageSizeBytes #{inspect(v)}"}
    end
  end

  defp v2_size(_, true), do: {:error, "maxMessageSizeBytes must be one unsigned 32-bit integer"}

  defp kinds([]), do: {:ok, nil}

  defp kinds(values) do
    Enum.reduce_while(values, {:ok, []}, fn
      v, {:ok, acc} when v in ["commit", "identity", "account", "sync"] ->
        {:cont, {:ok, [String.to_existing_atom(v) | acc]}}

      v, _ ->
        {:halt, {:error, "unknown kind #{inspect(v)} (valid: commit, identity, account, sync)"}}
    end)
  end

  defp dids([]), do: {:ok, nil}

  defp dids(values) do
    case Enum.find(values, &(not Syntax.valid_did?(&1))) do
      nil ->
        set = MapSet.new(values)
        if MapSet.size(set) > @max_dids, do: {:error, "too many wanted DIDs"}, else: {:ok, set}

      bad ->
        {:error, "invalid DID: #{bad}"}
    end
  end

  defp collections([], _), do: {:ok, {nil, []}}

  defp collections(values, strict_wildcards?) do
    Enum.reduce_while(values, {:ok, {MapSet.new(), []}}, fn raw, {:ok, {exact, prefixes}} ->
      cond do
        String.ends_with?(raw, ".*") ->
          head = String.trim_trailing(raw, "*")

          cond do
            strict_wildcards? and not Syntax.valid_nsid?(String.trim_trailing(raw, ".*") <> ".x") ->
              {:halt, {:error, "invalid collection wildcard: #{raw}"}}

            head in prefixes ->
              {:cont, {:ok, {exact, prefixes}}}

            MapSet.size(exact) + length(prefixes) + 1 > @max_collections ->
              {:halt, {:error, "too many wanted collections: > #{@max_collections}"}}

            true ->
              {:cont, {:ok, {exact, prefixes ++ [head]}}}
          end

        not Syntax.valid_nsid?(raw) ->
          {:halt, {:error, "invalid collection: #{raw}"}}

        MapSet.size(exact) + length(prefixes) + 1 > @max_collections and
            not MapSet.member?(exact, raw) ->
          {:halt, {:error, "too many wanted collections: > #{@max_collections}"}}

        true ->
          {:cont, {:ok, {MapSet.put(exact, raw), prefixes}}}
      end
    end)
  end

  # ------------------------------------------------------------ matching

  @spec wants?(t, Event.t()) :: boolean
  def wants?(%__MODULE__{} = f, %Event{} = e) do
    kind_ok?(f, e) and (f.dids == nil or MapSet.member?(f.dids, e.did)) and collection_ok?(f, e)
  end

  defp kind_ok?(%{kinds: nil}, _), do: true
  defp kind_ok?(%{kinds: kinds}, e), do: kind_class(e) in kinds

  defp kind_class(e) do
    if Event.commit?(e), do: :commit, else: e.kind
  end

  defp collection_ok?(%{exact: nil}, _), do: true

  defp collection_ok?(f, e) do
    not Event.commit?(e) or e.collection == "" or MapSet.member?(f.exact, e.collection) or
      Enum.any?(f.prefixes, &String.starts_with?(e.collection, &1))
  end
end
