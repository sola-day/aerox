defmodule Aerox.PDS.RepoLock do
  @moduledoc """
  FIFO per-repo write lock (DESIGN §5.1: one writer per repo at a time).
  Taken *before* a database connection, so writers waiting for a hot
  account hold no pool connection (bench/RESULTS.md: 32 writers on one
  account exhausted the pool). One GenServer per node; a holder that dies
  releases its lock through its monitor. Per node today; the multi-node
  decision (DESIGN §10 R3) swaps this for a cluster lock behind the same
  `with_lock/2`.
  """
  use GenServer

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, [], name: Keyword.get(opts, :name, __MODULE__))

  @doc "Runs `fun` while holding the write lock of `did`; waiters are served in order."
  @spec with_lock(String.t(), (-> result), GenServer.server()) :: result when result: term
  def with_lock(did, fun, server \\ __MODULE__) do
    :ok = GenServer.call(server, {:acquire, did}, :infinity)

    try do
      fun.()
    after
      GenServer.cast(server, {:release, did, self()})
    end
  end

  @impl true
  def init([]), do: {:ok, %{locks: %{}, monitors: %{}}}

  @impl true
  def handle_call({:acquire, did}, {pid, _} = from, state) do
    ref = Process.monitor(pid)
    state = put_in(state.monitors[ref], {did, pid})

    case state.locks[did] do
      nil ->
        {:reply, :ok, put_in(state.locks[did], {{pid, ref}, :queue.new()})}

      {holder, waiters} ->
        {:noreply, put_in(state.locks[did], {holder, :queue.in({from, pid, ref}, waiters)})}
    end
  end

  @impl true
  def handle_cast({:release, did, pid}, state), do: {:noreply, release(state, did, pid)}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} -> {:noreply, state}
      {{did, ^pid}, monitors} -> {:noreply, release(%{state | monitors: monitors}, did, pid)}
    end
  end

  defp release(state, did, pid) do
    case state.locks[did] do
      {{^pid, ref}, waiters} ->
        Process.demonitor(ref, [:flush])
        state = %{state | monitors: Map.delete(state.monitors, ref)}
        hand_over(state, did, waiters)

      {holder, waiters} ->
        # a waiter died before its turn: drop it from the queue
        waiters = :queue.filter(fn {_, p, _} -> p != pid end, waiters)
        put_in(state.locks[did], {holder, waiters})

      nil ->
        state
    end
  end

  defp hand_over(state, did, waiters) do
    case :queue.out(waiters) do
      {{:value, {from, pid, ref}}, rest} ->
        GenServer.reply(from, :ok)
        put_in(state.locks[did], {{pid, ref}, rest})

      {:empty, _} ->
        %{state | locks: Map.delete(state.locks, did)}
    end
  end
end
