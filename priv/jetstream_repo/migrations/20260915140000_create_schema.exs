defmodule Aerox.Jetstream.Repo.Migrations.CreateSchema do
  @moduledoc "First migration of the `jetstream` schema (STRUCTURE §7): pre-created by the bootstrap, re-asserted here."
  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS jetstream AUTHORIZATION aerox_jetstream")
    execute("REVOKE ALL ON SCHEMA jetstream FROM PUBLIC")
  end

  def down do
    execute("DROP SCHEMA IF EXISTS jetstream CASCADE")
  end
end
