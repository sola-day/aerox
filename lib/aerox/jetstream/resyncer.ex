defmodule Aerox.Jetstream.Resyncer do
  @moduledoc """
  Runs repo resyncs a few at a time: those a live `#sync` asks for, and every
  minute the failed repos whose back-off has elapsed (upstream's failed-repo
  retry loop). A DID already queued or running is not queued twice.
  """
  use GenServer
  require Logger
  alias Aerox.Jetstream.Repos

  @concurrency 4
  @retry_every 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Queues a resync; `sync_rev` is the live `#sync` row's rev, when there is one."
  def request(did, sync_rev \\ nil) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:request, did, sync_rev})
    end
  end

  @impl true
  def init(_) do
    Process.send_after(self(), :retry, @retry_every)
    {:ok, %{queue: :queue.new(), queued: MapSet.new(), running: %{}}}
  end

  @impl true
  def handle_cast({:request, did, rev}, state), do: {:noreply, state |> push(did, rev) |> run()}

  @impl true
  def handle_info(:retry, state) do
    Process.send_after(self(), :retry, @retry_every)
    state = Enum.reduce(Repos.due(100), state, &push(&2, &1, nil))
    {:noreply, run(state)}
  end

  def handle_info({ref, _result}, state) when is_map_key(state.running, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, run(%{state | running: Map.delete(state.running, ref)})}
  end

  def handle_info({:DOWN, ref, _, _, reason}, state) when is_map_key(state.running, ref) do
    Logger.warning("jetstream: resync #{state.running[ref]} crashed: #{inspect(reason)}")
    {:noreply, run(%{state | running: Map.delete(state.running, ref)})}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp push(state, did, rev) do
    running? = did in Map.values(state.running)

    if MapSet.member?(state.queued, did) or running?,
      do: state,
      else: %{
        state
        | queue: :queue.in({did, rev}, state.queue),
          queued: MapSet.put(state.queued, did)
      }
  end

  defp run(state) do
    if map_size(state.running) < @concurrency do
      case :queue.out(state.queue) do
        {{:value, {did, rev}}, queue} ->
          task =
            Task.Supervisor.async_nolink(Aerox.Jetstream.TaskSupervisor, fn ->
              Repos.resync(did, rev)
            end)

          run(%{
            state
            | queue: queue,
              queued: MapSet.delete(state.queued, did),
              running: Map.put(state.running, task.ref, did)
          })

        {:empty, _} ->
          state
      end
    else
      state
    end
  end
end
