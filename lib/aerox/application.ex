defmodule Aerox.Application do
  @moduledoc """
  Config-driven supervision tree (DESIGN §2, §21.9). `config :aerox, :services`
  says which services this node runs; each contributes its own subtree.
  """
  use Boundary,
    top_level?: true,
    deps: [
      Aerox,
      AeroxWeb,
      Aerox.PDS,
      Aerox.PLC,
      Aerox.Relay,
      Aerox.AppView,
      Aerox.ImageServer,
      Aerox.Identity,
      Aerox.Auth,
      Aerox.Labeler,
      Aerox.Jetstream
    ]

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
      {Phoenix.PubSub, name: Aerox.PubSub},
      # DESIGN §18.2: per-node ETS rate-limit buckets.
      Aerox.RateLimit
    ]
  end

  # Each service's repo starts under the service supervisor. The core-side
  # repos are independent even though they share a database (DESIGN §4.6).
  # Every service gets its own identity cache backed by its own schema
  # (DESIGN §20.1): never shared across the §4.6 boundary.
  # DESIGN §21.9: repo first, then the sequencer, then everything that
  # depends on it; rest_for_one so a sequencer restart restarts fan-out only.
  defp children_for(:pds) do
    [
      %{
        id: Aerox.PDS.Supervisor,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [
             [
               Aerox.PDS.Repo,
               Aerox.PDS.Clock,
               # DESIGN §11.2/§12.4: the DPoP verifier shared by OAuth and Spaces
               Aerox.Auth.DPoP,
               Aerox.PDS.RepoLock,
               Aerox.PDS.Sequencer,
               identity_cache(Aerox.PDS.Identity, Aerox.PDS.Repo),
               {Oban, Application.fetch_env!(:aerox, Oban.PDS)}
             ],
             [strategy: :rest_for_one, name: Aerox.PDS.Supervisor]
           ]}
      }
    ]
  end

  defp children_for(:plc),
    do: [Aerox.PLC.Repo, identity_cache(Aerox.PLC.Identity, Aerox.PLC.Repo)]

  # DESIGN §19/§21.4: repo, sequencer, identity cache, then the per-host
  # consumers (registry + dynamic supervisor + the resubscribe task).
  defp children_for(:relay) do
    [
      %{
        id: Aerox.Relay.Supervisor,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [
             [
               Aerox.Relay.Repo,
               Aerox.Relay.Sequencer,
               identity_cache(Aerox.Relay.Identity, Aerox.Relay.Repo),
               {Task.Supervisor, name: Aerox.Relay.TaskSupervisor}
             ] ++ collection_crawler() ++ Aerox.Relay.Consumers.child_specs(),
             [strategy: :rest_for_one, name: Aerox.Relay.Supervisor]
           ]}
      }
    ]
  end

  # DESIGN §15.1/§21.5: repo, identity cache, Oban (backfill), then the
  # Broadway ingest off the Relay (disabled where no Relay is configured).
  defp children_for(:appview) do
    ingest =
      if Application.get_env(:aerox, Aerox.AppView, [])[:ingest] == false,
        do: [],
        else: [Aerox.AppView.Ingest]

    # DESIGN §15.6: one subscribeLabels consumer per configured labeler
    labels = if Aerox.AppView.Config.labelers() == [], do: [], else: [Aerox.AppView.Labels]

    [
      %{
        id: Aerox.AppView.Supervisor,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [
             [
               Aerox.AppView.Repo,
               identity_cache(Aerox.AppView.Identity, Aerox.AppView.Repo),
               Aerox.AppView.RepoSync,
               # DESIGN §16: the image CDN runs inside the AppView service
               Aerox.ImageServer,
               {Oban, Application.fetch_env!(:aerox, Oban.Core)}
             ] ++ ingest ++ labels,
             [strategy: :rest_for_one, name: Aerox.AppView.Supervisor]
           ]}
      }
    ]
  end

  # DESIGN §17: repo, identity cache, then whatever the labeler service adds
  # (`Aerox.Labeler.children/0` when it exists).
  defp children_for(:labeler) do
    extra =
      if Code.ensure_loaded?(Aerox.Labeler.Supervisor) and
           function_exported?(Aerox.Labeler.Supervisor, :children, 0),
         do: Aerox.Labeler.Supervisor.children(),
         else: []

    [Aerox.Labeler.Repo, identity_cache(Aerox.Labeler.Identity, Aerox.Labeler.Repo)] ++ extra
  end

  # Jetstream: its repo, the segment manifest, then (unless disabled) the writer
  # that owns the log and the relay ingest feeding it.
  defp children_for(:jetstream) do
    [
      %{
        id: Aerox.Jetstream.Supervisor,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [
             Aerox.Jetstream.Supervisor.children(),
             [strategy: :rest_for_one, name: Aerox.Jetstream.Supervisor]
           ]}
      }
    ]
  end

  defp identity_cache(name, repo) do
    {Aerox.Identity.Cache,
     name: name, repo: repo, resolver: Application.get_env(:aerox, :identity_resolver, [])}
  end

  @impl true
  def config_change(changed, _new, removed) do
    AeroxWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # The collection directory's describeRepo sweep (listReposByCollection).
  defp collection_crawler do
    if Aerox.Relay.Config.get(:collection_crawler, true),
      do: [Aerox.Relay.CollectionCrawler],
      else: []
  end
end
