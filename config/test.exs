import Config

# The `_test` databases are created once by docker/postgres/init (VERIFICATION
# §11); test/test_helper.exs refuses to start if either is missing. Sandbox on
# every repo.
db_host = System.get_env("DATABASE_HOST", "127.0.0.1")
db_port = String.to_integer(System.get_env("DATABASE_PORT", "5433"))
partition = System.get_env("MIX_TEST_PARTITION")

for {repo, role, database} <- [
      {Aerox.PDS.Repo, "aerox_pds", "aerox_pds_test"},
      {Aerox.PLC.Repo, "aerox_plc", "aerox_core_test"},
      {Aerox.Relay.Repo, "aerox_relay", "aerox_core_test"},
      {Aerox.AppView.Repo, "aerox_appview", "aerox_core_test"}
    ] do
  config :aerox, repo,
    username: role,
    password: System.get_env("DATABASE_ROLE_PASSWORD", role),
    hostname: db_host,
    port: db_port,
    database: "#{database}#{partition}",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: System.schedulers_online() * 2
end

config :aerox, Aerox.PDS.Sequencer, unboxed: true
config :aerox, Aerox.Relay.Sequencer, unboxed: true

config :aerox, Aerox.Relay,
  hostname: "relay.aerox.sola.town",
  public_url: "https://relay.aerox.sola.town",
  allow_insecure_hosts: true,
  skip_account_host_check: false,
  resubscribe_on_start: false,
  admin_password: "REDACTED-relay-admin-password"

config :aerox, Aerox.Relay.HostChecker, plug: AeroxWeb.Endpoint, allow_private: true

# The PDS talks to the PLC directory over HTTP. In tests the "network" is the
# Phoenix endpoint itself, so the in-process directory (sandboxed) answers.
config :aerox, Aerox.PDS,
  public_url: "https://pds.aerox.sola.town",
  service_did: "did:web:pds.aerox.sola.town",
  handle_domains: [".aerox.sola.town", ".test"],
  plc_url: "https://plc.aerox.sola.town",
  jwt_secret: "test-jwt-secret-test-jwt-secret-test-jwt-secret"

config :aerox, Aerox.PDS.PlcOps, http: [plug: AeroxWeb.Endpoint]
config :aerox, Aerox.Identity.HTTP, plug: AeroxWeb.Endpoint, allow_private: true

config :aerox, Aerox.Crypto.Signer,
  adapter: Aerox.Crypto.Signer.Local,
  private_key_hex: "9085d2bef69286a6cbb51623c8fa258629945cd55ca705cc4e66700396894e0c"

config :aerox, Aerox.Blob.Store, adapter: Aerox.Blob.Disk, root: "tmp/test-blobs"
config :aerox, Oban.PDS, testing: :manual
config :aerox, Oban.Core, testing: :manual

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :aerox, AeroxWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "GIyVyLJJlFt7keFg+vAnPlze8LBYqqmeOVqJaFV9S9ER+e7U9arYy1RoYAFkt7s2",
  server: false

# DESIGN §18.2: no trusted proxies in test, so x-forwarded-for is ignored
# unless a test opts in with Application.put_env. Rate limits run at upstream's
# numbers; a test that needs to trip one sets
# `config :aerox, Aerox.RateLimit, overrides: %{name => buckets}` via put_env
# (read per call) and calls Aerox.RateLimit.reset/0 afterwards.
config :aerox, :trusted_proxies, []
config :aerox, Aerox.RateLimit, overrides: %{}

# In test we don't send emails
config :aerox, Aerox.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
