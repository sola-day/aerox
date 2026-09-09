defmodule Aerox.ImageServer.Semaphore do
  @moduledoc """
  A counting semaphore bounding concurrent libvips work (DESIGN §21.8). Callers
  block in `run/2` until a slot is free; a slot held by a process that dies is
  released by its monitor. Waiters that time out get `{:error, :busy}`.
  """
  use GenServer

  @default_limit 4
  @default_wait 10_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Runs `fun` inside a slot; `{:error, :busy}` if none frees up within `timeout`."
  @spec run(atom, (-> result), timeout) :: result | {:error, :busy} when result: term
  def run(name \\ __MODULE__, fun, timeout \\ @default_wait) do
    case acquire(name, timeout) do
      :ok ->
        try do
          fun.()
        after
          release(name)
        end

      {:error, :busy} = e ->
        e
    end
  end

  def acquire(name \\ __MODULE__, timeout \\ @default_wait) do
    try do
      GenServer.call(name, :acquire, timeout)
    catch
      :exit, {:timeout, _} ->
        GenServer.cast(name, {:cancel, self()})
        {:error, :busy}
    end
  end

  def release(name \\ __MODULE__), do: GenServer.cast(name, {:release, self()})

  @doc "Slots in use and waiters queued (tests and telemetry)."
  def stats(name \\ __MODULE__), do: GenServer.call(name, :stats)

  @impl true
  def init(opts) do
    {:ok,
     %{
       limit: Keyword.get(opts, :limit, @default_limit),
       holders: %{},
       waiters: :queue.new()
     }}
  end

  @impl true
  def handle_call(:acquire, {pid, _} = from, state) do
    if map_size(state.holders) < state.limit do
      {:reply, :ok, grant(state, pid)}
    else
      {:noreply, %{state | waiters: :queue.in(from, state.waiters)}}
    end
  end

  def handle_call(:stats, _from, state) do
    {:reply, %{in_use: map_size(state.holders), waiting: :queue.len(state.waiters)}, state}
  end

  @impl true
  def handle_cast({:release, pid}, state), do: {:noreply, free(state, pid)}

  def handle_cast({:cancel, pid}, state) do
    waiters = :queue.filter(fn {p, _} -> p != pid end, state.waiters)
    {:noreply, %{state | waiters: waiters}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state), do: {:noreply, free(state, pid)}

  defp grant(state, pid) do
    ref = Process.monitor(pid)
    %{state | holders: Map.put(state.holders, pid, ref)}
  end

  defp free(state, pid) do
    case Map.pop(state.holders, pid) do
      {nil, _} ->
        state

      {ref, holders} ->
        Process.demonitor(ref, [:flush])
        state = %{state | holders: holders}

        case :queue.out(state.waiters) do
          {{:value, {next_pid, _} = from}, waiters} ->
            GenServer.reply(from, :ok)
            grant(%{state | waiters: waiters}, next_pid)

          {:empty, _} ->
            state
        end
    end
  end
end
