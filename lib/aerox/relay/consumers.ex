defmodule Aerox.Relay.Consumers do
  @moduledoc "The DynamicSupervisor + Registry of per-host consumers (DESIGN §21.4)."
  require Logger
  alias Aerox.Relay.{Consumer, Hosts}
  alias Aerox.Relay.Schema.Host

  @reconcile_every 60_000

  def child_specs do
    [
      {Registry, keys: :unique, name: Aerox.Relay.ConsumerRegistry},
      {DynamicSupervisor,
       name: Aerox.Relay.ConsumerSupervisor,
       strategy: :one_for_one,
       max_restarts: 20,
       max_seconds: 60},
      %{
        id: Aerox.Relay.Resubscribe,
        start: {Task, :start_link, [&resubscribe_all/0]},
        restart: :temporary
      },
      Aerox.Relay.Consumers.Reconciler
    ]
  end

  @doc "Starts a consumer for the host row unless one runs already."
  def subscribe(%Host{} = host) do
    case DynamicSupervisor.start_child(Aerox.Relay.ConsumerSupervisor, {Consumer, host}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def unsubscribe(hostname) do
    case Registry.lookup(Aerox.Relay.ConsumerRegistry, hostname) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Aerox.Relay.ConsumerSupervisor, pid)
      [] -> :ok
    end
  end

  def subscribed?(hostname), do: Registry.lookup(Aerox.Relay.ConsumerRegistry, hostname) != []

  @doc """
  Subscribes every active host that has no consumer.

  The row and the process can disagree — a consumer can stop for good (its
  supervisor giving up after repeated crashes, say) while the host still reads
  `active`. Nothing then consumes that host, and because every HTTP surface
  keeps answering, it is invisible until someone notices that no events arrive.
  `Reconciler` runs this on a timer so the disagreement lasts a minute rather
  than until the next restart.
  """
  def reconcile do
    for host <- Hosts.active(), not subscribed?(host.hostname) do
      Logger.warning("relay: host is active with no consumer, re-subscribing host=#{host.hostname}")
      subscribe(host)
    end

    :ok
  end

  def reconcile_every,
    do: Application.get_env(:aerox, Aerox.Relay, [])[:reconcile_every_ms] || @reconcile_every

  def enabled?, do: Application.get_env(:aerox, Aerox.Relay, [])[:resubscribe_on_start] != false

  @doc "On start, reconnect to every active host (indigo `ResubscribeAllHosts`)."
  def resubscribe_all do
    if Application.get_env(:aerox, Aerox.Relay, [])[:resubscribe_on_start] != false do
      Enum.each(Hosts.active(), fn host ->
        subscribe(host)
        Process.sleep(1)
      end)
    end

    :ok
  end

  defmodule Reconciler do
    @moduledoc "Runs `Aerox.Relay.Consumers.reconcile/0` on a timer."
    use GenServer
    alias Aerox.Relay.Consumers

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts) do
      if Consumers.enabled?(), do: :timer.send_interval(Consumers.reconcile_every(), :reconcile)
      {:ok, %{}}
    end

    @impl true
    def handle_info(:reconcile, state) do
      Consumers.reconcile()
      {:noreply, state}
    end

    def handle_info(_, state), do: {:noreply, state}
  end
end
