defmodule AeroxWeb.LabelerRouter do
  @moduledoc """
  The Labeler's HTTP surface (DESIGN §17), dispatched by `AeroxWeb.Dispatch`
  when the request host is `Aerox.Labeler.Config.hostname/0`:
  `com.atproto.label.*`, report intake, and the moderation admin API.
  """
  use AeroxWeb, :router

  pipeline :labeler do
    plug AeroxWeb.Plugs.CORS
    plug :accepts, ["json"]
    plug AeroxWeb.Plugs.ClientIP
    plug AeroxWeb.Plugs.RateLimit, :global_ip
    plug AeroxWeb.Plugs.ServiceEnabled, :labeler
  end

  scope "/", AeroxWeb.Labeler do
    pipe_through :labeler
    get "/_health", MetaController, :health
    get "/.well-known/did.json", MetaController, :did_json
  end

  scope "/xrpc", AeroxWeb.Labeler do
    pipe_through :labeler
    options "/*path", MetaController, :not_implemented
    match :*, "/*method", MetaController, :not_implemented
  end
end
