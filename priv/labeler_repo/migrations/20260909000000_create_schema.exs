defmodule Aerox.Labeler.Repo.Migrations.CreateSchema do
  @moduledoc "First migration of the `labeler` schema (STRUCTURE §7): pre-created by the bootstrap, re-asserted here."
  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS labeler AUTHORIZATION aerox_labeler")
    execute("REVOKE ALL ON SCHEMA labeler FROM PUBLIC")
  end

  def down do
    execute("DROP SCHEMA IF EXISTS labeler CASCADE")
  end
end
