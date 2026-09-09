defmodule AeroxWeb.RelayRouter do
  @moduledoc """
  The Relay's HTTP surface (DESIGN §19), dispatched by `AeroxWeb.Dispatch`
  when the request host is `Aerox.Relay.Config.hostname/0`. Route for route
  with indigo's relay: the sync subset it serves, 501 for the deprecated
  methods, and the non-archival answer for repo-content methods.
  """
  use AeroxWeb, :router

  pipeline :relay do
    plug AeroxWeb.Plugs.CORS
    plug :accepts, ["json", "cbor", "car"]
    plug AeroxWeb.Plugs.ClientIP
    plug AeroxWeb.Plugs.RateLimit, :global_ip
    plug AeroxWeb.Plugs.ServiceEnabled, :relay
    plug AeroxWeb.Relay.AdminAuth
  end

  scope "/", AeroxWeb.Relay do
    pipe_through :relay

    get "/", SyncController, :home
    get "/_health", SyncController, :health
    get "/.well-known/did.json", SyncController, :did_json
  end

  scope "/xrpc", AeroxWeb do
    pipe_through :relay
    get "/com.atproto.sync.subscribeRepos", Sockets.Firehose.Plug, Aerox.Relay.Sequencer
  end

  scope "/xrpc", AeroxWeb.Relay do
    pipe_through :relay

    options "/*path", SyncController, :not_implemented
    post "/com.atproto.sync.requestCrawl", SyncController, :request_crawl
    get "/com.atproto.sync.listHosts", SyncController, :list_hosts
    get "/com.atproto.sync.getHostStatus", SyncController, :get_host_status
    get "/com.atproto.sync.listRepos", SyncController, :list_repos
    get "/com.atproto.sync.getRepoStatus", SyncController, :get_repo_status
    get "/com.atproto.sync.getLatestCommit", SyncController, :get_latest_commit

    # non-archival (DESIGN §19): the hosting PDS answers these
    get "/com.atproto.sync.getRepo", SyncController, :not_archival
    get "/com.atproto.sync.getRecord", SyncController, :not_archival
    get "/com.atproto.sync.getBlocks", SyncController, :not_archival
    get "/com.atproto.sync.getBlob", SyncController, :not_archival
    get "/com.atproto.sync.listBlobs", SyncController, :not_archival
    get "/com.atproto.sync.listReposByCollection", SyncController, :not_implemented

    # deprecated
    get "/com.atproto.sync.getCheckout", SyncController, :not_implemented
    get "/com.atproto.sync.getHead", SyncController, :not_implemented
    post "/com.atproto.sync.notifyOfUpdate", SyncController, :not_implemented

    # admin (indigo handlers_admin.go subset)
    post "/admin.subscribeHost", SyncController, :admin_subscribe_host
    post "/admin.setHostAccountLimit", SyncController, :admin_set_account_limit
    post "/admin.banDomain", SyncController, :admin_ban_domain
    post "/admin.setHostStatus", SyncController, :admin_set_host_status

    match :*, "/*method", SyncController, :not_implemented
  end
end
