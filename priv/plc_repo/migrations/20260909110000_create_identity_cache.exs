defmodule Aerox.PLC.Repo.Migrations.CreateIdentityCache do
  @moduledoc "Per-service persistent identity cache (DESIGN §20.1): never shared across the §4.6 boundary."
  use Ecto.Migration

  def change do
    create table(:identity_cache, primary_key: false) do
      add :did, :text, primary_key: true
      add :doc, :map, null: false
      add :handle, :text
      add :fetched_at, :utc_datetime_usec, null: false
    end

    create index(:identity_cache, [:handle])
  end
end
