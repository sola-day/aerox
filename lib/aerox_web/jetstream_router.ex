defmodule AeroxWeb.JetstreamRouter do
  @moduledoc """
  Jetstream's HTTP surface, dispatched by `AeroxWeb.Dispatch` when the request
  host is `Aerox.Jetstream.Config.hostname/0`: the legacy `/subscribe` stream,
  `network.bsky.jetstream.subscribeEvents`, the archive (`listSegments`,
  `getSegment`, `getBlock`, `planSnapshot`), `getZstdDictionary`, and the
  bearer-gated timestamp import.
  """
  use AeroxWeb, :router

  pipeline :jetstream do
    plug AeroxWeb.Plugs.CORS
    plug AeroxWeb.Plugs.ClientIP
    plug AeroxWeb.Plugs.RateLimit, :global_ip
    plug AeroxWeb.Plugs.ServiceEnabled, :jetstream
  end

  scope "/", AeroxWeb.Jetstream do
    pipe_through :jetstream
    get "/", MetaController, :home
    get "/_health", MetaController, :health
    get "/subscribe", SubscribePlug, :v1
  end

  scope "/xrpc", AeroxWeb.Jetstream do
    pipe_through :jetstream
    options "/*path", MetaController, :not_implemented

    get "/network.bsky.jetstream.subscribeEvents", SubscribePlug, :v2
    get "/network.bsky.jetstream.getZstdDictionary", ArchiveController, :get_zstd_dictionary
    get "/network.bsky.jetstream.listSegments", ArchiveController, :list_segments
    get "/network.bsky.jetstream.getSegment", ArchiveController, :get_segment
    get "/network.bsky.jetstream.getBlock", ArchiveController, :get_block
    post "/network.bsky.jetstream.planSnapshot", ArchiveController, :plan_snapshot
    post "/network.bsky.jetstream.importTimestamps", ImportController, :import_timestamps
    get "/network.bsky.jetstream.getImportStatus", ImportController, :get_import_status

    match :*, "/*method", MetaController, :not_implemented
  end
end
