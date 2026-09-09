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

config :aerox, Oban.PDS, testing: :manual
config :aerox, Oban.Core, testing: :manual

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :aerox, AeroxWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "GIyVyLJJlFt7keFg+vAnPlze8LBYqqmeOVqJaFV9S9ER+e7U9arYy1RoYAFkt7s2",
  server: false

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
