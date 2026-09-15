defmodule Aerox.Relay.CollectionCrawler do
  @moduledoc """
  Fills the collection directory for accounts whose records predate the
  relay's view of them (`Aerox.Relay.Collections.crawl/1`): every account never
  crawled — on start, then as they are first seen — and any account after a
  `#sync`, which may have replaced its repo. A few `describeRepo` calls run at a
  time; a failure leaves the account uncrawled and it is retried on the next
  sweep.
  """
  use GenServer
  require Logger
  alias Aerox.Relay.Collections

  @concurrency 4
  @sweep_every :timer.minutes(10)
  @batch 200

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Asks for `did` to be (re)crawled. A no-op where the crawler is not running."
  def enqueue(did) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:enqueue, did})
    end
  end

  @impl true
  def init(_) do
    send(self(), :sweep)
    {:ok, %{queue: :queue.new(), queued: MapSet.new(), running: %{}}}
  end

  @impl true
  def handle_cast({:enqueue, did}, state), do: {:noreply, state |> push(did) |> run()}

  @impl true
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @sweep_every)

    state =
      try do
        @batch |> Collections.uncrawled() |> Enum.reduce(state, &push(&2, &1))
      rescue
        e ->
          Logger.warning("relay: collection sweep failed: #{Exception.message(e)}")
          state
      end

    {:noreply, run(state)}
  end

  def handle_info({ref, result}, state) when is_map_key(state.running, ref) do
    Process.demonitor(ref, [:flush])
    {did, running} = Map.pop(state.running, ref)

    case result do
      :ok -> :ok
      other -> Logger.info("relay: collections crawl did=#{did} failed: #{inspect(other)}")
    end

    {:noreply, run(%{state | running: running})}
  end

  def handle_info({:DOWN, ref, _, _, reason}, state) when is_map_key(state.running, ref) do
    {did, running} = Map.pop(state.running, ref)
    Logger.warning("relay: collections crawl did=#{did} crashed: #{inspect(reason)}")
    {:noreply, run(%{state | running: running})}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp push(state, did) do
    if MapSet.member?(state.queued, did),
      do: state,
      else: %{state | queue: :queue.in(did, state.queue), queued: MapSet.put(state.queued, did)}
  end

  defp run(state) do
    if map_size(state.running) < @concurrency do
      case :queue.out(state.queue) do
        {{:value, did}, queue} ->
          task =
            Task.Supervisor.async_nolink(Aerox.Relay.TaskSupervisor, fn ->
              Collections.crawl(did)
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
