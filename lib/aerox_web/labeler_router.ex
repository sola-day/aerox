defmodule AeroxWeb.LabelerRouter do
  @moduledoc """
  The Labeler's HTTP surface (DESIGN §17), dispatched by `AeroxWeb.Dispatch`
  when the request host is `Aerox.Labeler.Config.hostname/0`:
  `com.atproto.label.*` (queryLabels, subscribeLabels), report intake
  (`com.atproto.moderation.createReport`) and the moderation admin API
  (`aerox.moderation.*`, DESIGN §17.3).
  """
  use AeroxWeb, :router

  pipeline :labeler do
    plug AeroxWeb.Plugs.CORS
    plug :accepts, ["json"]
    plug AeroxWeb.Plugs.ClientIP
    plug AeroxWeb.Plugs.RateLimit, :global_ip
    plug AeroxWeb.Plugs.ServiceEnabled, :labeler
    plug AeroxWeb.Labeler.Auth
  end

  scope "/", AeroxWeb.Labeler do
    pipe_through :labeler
    get "/_health", MetaController, :health
    get "/.well-known/did.json", MetaController, :did_json
  end

  scope "/xrpc", AeroxWeb do
    pipe_through :labeler

    get "/com.atproto.label.subscribeLabels",
        Sockets.Firehose.Plug,
        Aerox.Labeler.Labels.Source
  end

  scope "/xrpc", AeroxWeb.Labeler do
    pipe_through :labeler
    options "/*path", MetaController, :not_implemented
    get "/_health", MetaController, :health

    get "/com.atproto.label.queryLabels", LabelController, :query_labels
    get "/com.atproto.temp.fetchLabels", LabelController, :fetch_labels
    post "/com.atproto.moderation.createReport", ModerationController, :create_report

    # the admin API a frontend drives (DESIGN §17.3)
    post "/aerox.moderation.emitEvent", ModerationController, :emit_event
    get "/aerox.moderation.queryEvents", ModerationController, :query_events
    get "/aerox.moderation.queryReports", ModerationController, :query_reports

    match :*, "/*method", MetaController, :not_implemented
  end
end
