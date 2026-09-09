defmodule Aerox.Relay.Consumers do
  @moduledoc "The DynamicSupervisor + Registry of per-host consumers (DESIGN §21.4)."
  alias Aerox.Relay.{Consumer, Hosts}
  alias Aerox.Relay.Schema.Host

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
      }
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
end
