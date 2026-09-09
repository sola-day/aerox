defmodule AeroxWeb.Router do
  use AeroxWeb, :router

  # DESIGN §2: XRPC, the PLC REST surface and the well-known routes are API
  # pipelines of their own; :browser serves only LiveDashboard and the OAuth
  # pages.
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AeroxWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :plc do
    plug :accepts, ["json"]
    plug AeroxWeb.Plugs.ServiceEnabled, :plc
  end

  scope "/", AeroxWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # The did:plc directory, route for route with did-method-plc's server.
  scope "/", AeroxWeb.PLC do
    pipe_through :plc

    get "/_health", PLCController, :health
    get "/export", PLCController, :export
    post "/admin/removeInvalidOps", PLCController, :remove_invalid_ops
    get "/:did", PLCController, :document, did: ~r/^did:plc:[a-z2-7]{24}$/
    get "/:did/data", PLCController, :data, did: ~r/^did:plc:[a-z2-7]{24}$/
    get "/:did/log", PLCController, :log, did: ~r/^did:plc:[a-z2-7]{24}$/
    get "/:did/log/audit", PLCController, :audit, did: ~r/^did:plc:[a-z2-7]{24}$/
    get "/:did/log/last", PLCController, :last, did: ~r/^did:plc:[a-z2-7]{24}$/
    post "/:did", PLCController, :submit, did: ~r/^did:plc:[a-z2-7]{24}$/
  end

  if Application.compile_env(:aerox, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AeroxWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
