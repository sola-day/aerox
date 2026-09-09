defmodule Aerox.Relay.Repo.Migrations.CreateSchema do
  @moduledoc """
  First migration of the `relay` schema (STRUCTURE §7, DESIGN §4.6). Runs as
  the `aerox_relay` role. The schema itself is created by the database
  bootstrap (docker/postgres/init), owned by this role, because Ecto records
  `schema_migrations` wherever `search_path` points and so needs the schema
  before any migration can run (STRUCTURE §10). This migration is the
  in-repo record of that ownership and re-asserts it idempotently.
  """
  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS relay AUTHORIZATION aerox_relay")
    execute("REVOKE ALL ON SCHEMA relay FROM PUBLIC")
  end

  def down do
    execute("DROP SCHEMA IF EXISTS relay CASCADE")
  end
end
