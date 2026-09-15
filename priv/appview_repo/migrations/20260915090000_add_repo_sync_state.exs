defmodule Aerox.AppView.Repo.Migrations.AddRepoSyncState do
  @moduledoc """
  Record-level synchronisation (Sync spec, "Reliable Repository
  Synchronization"; `Aerox.AppView.RepoSync`): each repo's sync status and the
  `data` root of its last applied commit, so a `#commit` can be checked against
  the previous state with `since` and `prevData`, plus the events that arrive
  while a repo is being re-synchronised.

  Rows that exist already were indexed live and are taken as synchronised;
  their `data_cid` is unknown, so the first commit after this migration is
  checked on `since` alone.
  """
  use Ecto.Migration

  def change do
    alter table(:actor_sync) do
      modify :commit_cid, :text, null: true, from: {:text, null: false}
      add :data_cid, :text
      add :status, :text, null: false, default: "synchronized"
      add :updated_at, :utc_datetime_usec
    end

    create index(:actor_sync, [:status], where: "status <> 'synchronized'")

    create table(:actor_sync_pending) do
      add :did, :text, null: false
      add :seq, :bigint, null: false
      add :type, :text, null: false
      add :rev, :text, null: false
      add :body, :binary, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:actor_sync_pending, [:did, :seq])
  end
end
