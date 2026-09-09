# VERIFICATION §11: the two `_test` databases are created once, outside the
# test run; refuse to start rather than silently create or skip.
for repo <- [Aerox.PDS.Repo, Aerox.PLC.Repo, Aerox.Relay.Repo, Aerox.AppView.Repo] do
  config = repo.config()

  case Postgrex.start_link(
         Keyword.take(config, [:hostname, :port, :username, :password, :database])
       ) do
    {:ok, conn} ->
      Postgrex.query!(conn, "SELECT 1", [])
      GenServer.stop(conn)

    {:error, reason} ->
      raise "#{inspect(repo)} cannot reach #{config[:database]} as #{config[:username]}: " <>
              inspect(reason) <>
              "\nCreate it with docker/postgres/init/01-databases.sh (VERIFICATION §11)."
  end
end

ExUnit.start()

for repo <- [Aerox.PDS.Repo, Aerox.PLC.Repo, Aerox.Relay.Repo, Aerox.AppView.Repo] do
  Ecto.Adapters.SQL.Sandbox.mode(repo, :manual)
end

Mox.defmock(Aerox.Identity.DNSMock, for: Aerox.Identity.DNS)
