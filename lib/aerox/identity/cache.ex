defmodule Aerox.Identity.Cache do
  @moduledoc """
  The two-layer identity cache (DESIGN §20.1, §21.7): an ETS table per
  service (documents 1 h TTL, handles 10 min, negative results 1 min;
  `max_age:` lets auth flows demand ≤ 10 min), a persistent
  `identity_cache` row in the service's own schema for warm restarts, and
  single-flight misses so a hundred concurrent lookups of one DID make one
  fetch. Explicit invalidation on `#identity` events.

  Start one per service: `{Aerox.Identity.Cache, name: Aerox.PLC.Identity, repo: Aerox.PLC.Repo}`.
  The process only owns the table and the sweeper; reads never go through it.
  """
  use GenServer
  require Ecto.Query
  alias Aerox.ATProto.Identity, as: Doc
  alias Aerox.Identity.Resolver

  @doc_ttl 3_600_000
  @handle_ttl 600_000
  @negative_ttl 60_000
  @sweep_every 60_000

  # ------------------------------------------------------------ public

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts),
    do: %{id: Keyword.fetch!(opts, :name), start: {__MODULE__, :start_link, [opts]}}

  @doc "DID document, cached. `max_age:` (ms) forces a refresh of older entries; `force: true` bypasses the cache."
  @spec resolve_did(atom, String.t(), keyword) :: {:ok, Doc.doc()} | {:error, term}
  def resolve_did(cache, did, opts \\ []) do
    lookup(cache, {:did, did}, opts, fn -> Resolver.resolve_did(did, resolver_opts(cache)) end)
  end

  @doc "Handle → DID, cached (10 min)."
  @spec resolve_handle(atom, String.t(), keyword) :: {:ok, String.t()} | {:error, term}
  def resolve_handle(cache, handle, opts \\ []) do
    lookup(cache, {:handle, handle}, opts, fn ->
      Resolver.resolve_handle(handle, resolver_opts(cache))
    end)
  end

  @doc "Drops every entry for a DID (and its handle), on `#identity`."
  @spec invalidate(atom, String.t()) :: :ok
  def invalidate(cache, did) do
    table = table(cache)

    case :ets.lookup(table, {:did, did}) do
      [{_, {:ok, doc}, _, _}] -> for h <- Doc.handles(doc), do: :ets.delete(table, {:handle, h})
      _ -> :ok
    end

    :ets.delete(table, {:did, did})
    GenServer.cast(cache, {:forget, did})
    :ok
  end

  @doc "Empties the table (tests)."
  def clear(cache), do: :ets.delete_all_objects(table(cache))

  defp lookup(cache, key, opts, fetch) do
    table = table(cache)
    now = System.monotonic_time(:millisecond)
    max_age = Keyword.get(opts, :max_age)

    fresh =
      if Keyword.get(opts, :force, false) do
        nil
      else
        case :ets.lookup(table, key) do
          [{^key, value, expires_at, stored_at}] when expires_at > now ->
            if max_age && now - stored_at >= max_age, do: nil, else: value

          _ ->
            nil
        end
      end

    case fresh do
      nil -> single_flight(cache, key, fn -> fetch_and_store(cache, key, fetch) end)
      value -> value
    end
  end

  # One in-flight fetch per key (DESIGN §21.7): a transient process
  # registered under the key does the fetch and answers everyone who asked
  # while it was alive; anyone arriving after it exited finds the ETS entry.
  @flight_grace 200

  defp single_flight(cache, key, fun, attempts \\ 0) do
    registry = registry(cache)

    pid =
      case Registry.lookup(registry, {:flight, key}) do
        [{pid, _}] ->
          pid

        [] ->
          # our own flight: it wins the registration or exits at once
          spawn(fn ->
            case Registry.register(registry, {:flight, key}, nil) do
              {:ok, _} ->
                result = fun.()
                # leave the registry before answering, so a refresh that
                # arrives now starts a new flight instead of joining this one
                Registry.unregister(registry, {:flight, key})
                reply_loop(result)

              {:error, _} ->
                :ok
            end
          end)
      end

    ref = Process.monitor(pid)
    send(pid, {:await, self(), ref})

    receive do
      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, _, _, _} ->
        # the flight lost the race or finished before we asked: the answer is
        # in ETS, or another flight owns the key now
        case :ets.lookup(table(cache), key) do
          [{^key, value, _, stored_at}] when stored_at >= attempts -> value
          _ when attempts < 5 -> single_flight(cache, key, fun, attempts + 1)
          _ -> fun.()
        end
    after
      15_000 ->
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end

  defp reply_loop(result) do
    receive do
      {:await, from, ref} ->
        send(from, {ref, result})
        reply_loop(result)
    after
      @flight_grace -> :ok
    end
  end

  defp fetch_and_store(cache, key, fetch) do
    result = fetch.()
    now = System.monotonic_time(:millisecond)

    ttl =
      case {key, result} do
        {{:did, _}, {:ok, _}} -> @doc_ttl
        {{:handle, _}, {:ok, _}} -> @handle_ttl
        _ -> @negative_ttl
      end

    :ets.insert(table(cache), {key, result, now + ttl, now})

    if match?({{:did, _}, {:ok, _}}, {key, result}),
      do: GenServer.cast(cache, {:persist, elem(key, 1), elem(result, 1)})

    result
  end

  defp resolver_opts(cache) do
    case :ets.lookup(table(cache), :config) do
      [{:config, opts}] -> opts
      _ -> []
    end
  end

  defp table(cache), do: :persistent_term.get({__MODULE__, cache, :table})
  defp registry(cache), do: :persistent_term.get({__MODULE__, cache, :registry})

  # ------------------------------------------------------------ server

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    table = :ets.new(name, [:set, :public, read_concurrency: true])
    registry = Module.concat(name, Flights)
    {:ok, _} = Registry.start_link(keys: :unique, name: registry)
    :persistent_term.put({__MODULE__, name, :table}, table)
    :persistent_term.put({__MODULE__, name, :registry}, registry)
    :ets.insert(table, {:config, Keyword.get(opts, :resolver, [])})
    Process.send_after(self(), :sweep, @sweep_every)
    {:ok, %{table: table, repo: Keyword.get(opts, :repo), name: name}}
  end

  @impl true
  def handle_cast({:persist, did, doc}, %{repo: repo} = state) when not is_nil(repo) do
    try do
      repo.insert_all(
        "identity_cache",
        [%{did: did, doc: doc, handle: Doc.handle(doc), fetched_at: DateTime.utc_now()}],
        on_conflict: {:replace, [:doc, :handle, :fetched_at]},
        conflict_target: :did
      )
    rescue
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_cast({:forget, did}, %{repo: repo} = state) when not is_nil(repo) do
    try do
      repo.delete_all(Ecto.Query.from(c in "identity_cache", where: c.did == ^did))
    rescue
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_cast(_, state), do: {:noreply, state}

  @impl true
  def handle_info(:sweep, %{table: table} = state) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(table, [{{:"$1", :_, :"$2", :_}, [{:<, :"$2", now}], [true]}])
    Process.send_after(self(), :sweep, @sweep_every)
    {:noreply, state}
  end
end
