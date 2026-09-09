# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
import Config

# Four Ecto repos over two databases (DESIGN §4.6, STRUCTURE §7). The three
# `aerox_core` repos each pin their own schema: `migration_default_prefix`
# puts `schema_migrations` inside it, and `after_connect` sets `search_path`
# so unqualified table names resolve there and nowhere else.
config :aerox,
  ecto_repos: [
    Aerox.PDS.Repo,
    Aerox.PLC.Repo,
    Aerox.Relay.Repo,
    Aerox.AppView.Repo,
    Aerox.Labeler.Repo
  ],
  generators: [timestamp_type: :utc_datetime]

config :aerox, Aerox.PDS.Repo, priv: "priv/pds_repo"

for {repo, schema} <- [
      {Aerox.PLC.Repo, "plc"},
      {Aerox.Relay.Repo, "relay"},
      {Aerox.AppView.Repo, "appview"},
      {Aerox.Labeler.Repo, "labeler"}
    ] do
  config :aerox, repo,
    priv: "priv/#{schema}_repo",
    migration_default_prefix: schema,
    after_connect: {Postgrex, :query!, ["SET search_path TO #{schema}, public", []]}
end

# Which services this node runs (DESIGN §2). Dev and test run everything.
config :aerox, :services, [:pds, :plc, :relay, :appview, :labeler]

# Two Oban instances, one per database (DESIGN §21.6, §4.6). Queues are added
# by the milestone that first enqueues to them.
config :aerox, Oban.PDS,
  name: Aerox.PDS.Oban,
  repo: Aerox.PDS.Repo,
  queues: [mail: 5, maintenance: 2],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       {"0 * * * *", Aerox.PDS.Jobs.ReapBlobs},
       {"*/10 * * * *", Aerox.PDS.Jobs.ReapSignups},
       {"30 3 * * *", Aerox.PDS.Jobs.RevokeExpiredTokens}
     ]}
  ]

config :aerox, Oban.Core,
  name: Aerox.Core.Oban,
  repo: Aerox.AppView.Repo,
  prefix: "appview",
  queues: [backfill: 2, maintenance: 1],
  plugins: [Oban.Plugins.Pruner]

# Configure the endpoint
config :aerox, AeroxWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AeroxWeb.ErrorHTML, json: AeroxWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Aerox.PubSub,
  live_view: [signing_salt: "8SaRx7Dx"]

# DESIGN §2: without these registrations `plug :accepts` answers 406.
config :mime, :types, %{
  "application/cbor" => ["cbor"],
  "application/vnd.ipld.car" => ["car"],
  "application/jsonl" => ["jsonl"]
}

config :aerox, Aerox.Mailer, adapter: Swoosh.Adapters.Local

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Image CDN (DESIGN §16): processed renditions on local disk, bounded by
# `max_bytes`; libvips work bounded by `concurrency`; sources refused above
# `max_source_bytes` / `max_pixels`. `quality` is upstream's (100).
config :aerox, Aerox.ImageServer,
  max_bytes: 1024 * 1024 * 1024,
  sweep_interval: 600_000,
  sweeper: true,
  concurrency: 4,
  max_source_bytes: 20 * 1024 * 1024,
  max_pixels: 50_000_000,
  quality: 100

# Origin fetches go through Aerox.Identity.HTTP (SSRF rules) to the PDS named
# in the owner's DID document, resolved through the AppView's identity cache.
config :aerox, Aerox.ImageServer.Origin,
  identity_cache: Aerox.AppView.Identity,
  timeout: 10_000

# Aerox.PDS.Config.signer/0 refuses Signer.Local outside dev/test (DESIGN §14.2).
config :aerox, env: config_env()

import_config "#{config_env()}.exs"
