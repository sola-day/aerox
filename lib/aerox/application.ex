defmodule Aerox.Application do
  @moduledoc """
  Config-driven supervision tree (DESIGN §2, §21.9). `config :aerox, :services`
  says which services this node runs; each contributes its own subtree.
  """
  use Boundary, top_level?: true, deps: [Aerox, AeroxWeb]
  use Application

  @impl true
  def start(_type, _args) do
    children =
      base_children() ++
        Enum.flat_map(Aerox.Services.enabled(), &children_for/1) ++
        [AeroxWeb.Endpoint]

    Supervisor.start_link(children, strategy: :one_for_one, name: Aerox.Supervisor)
  end

  defp base_children do
    [
      AeroxWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:aerox, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Aerox.PubSub}
    ]
  end

  # Each service's repo starts under the service supervisor. The core-side
  # repos are independent even though they share a database (DESIGN §4.6).
  defp children_for(:pds), do: [Aerox.PDS.Repo, {Oban, Application.fetch_env!(:aerox, Oban.PDS)}]
  defp children_for(:plc), do: [Aerox.PLC.Repo]
  defp children_for(:relay), do: [Aerox.Relay.Repo]

  defp children_for(:appview),
    do: [Aerox.AppView.Repo, {Oban, Application.fetch_env!(:aerox, Oban.Core)}]

  defp children_for(:labeler), do: []

  @impl true
  def config_change(changed, _new, removed) do
    AeroxWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
