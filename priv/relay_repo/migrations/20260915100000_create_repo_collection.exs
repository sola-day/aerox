defmodule Aerox.Relay.Repo.Migrations.CreateRepoCollection do
  @moduledoc """
  The collection directory behind `com.atproto.sync.listReposByCollection`
  (Sync spec, "Record-Level Synchronization"; indigo `collectiondir`): which
  DIDs have records in which collection. `id` orders a collection's DIDs by
  first sight, so a client paging with a cursor also sees repos that appear
  while it pages. `account.collections_crawled_at` marks accounts whose
  existing collections have been read with `describeRepo`.
  """
  use Ecto.Migration

  def change do
    create table(:repo_collection, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :collection, :text, null: false
      add :did, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:repo_collection, [:collection, :did])
    create index(:repo_collection, [:collection, :id])
    create index(:repo_collection, [:did])

    alter table(:account) do
      add :collections_crawled_at, :utc_datetime_usec
    end
  end
end
