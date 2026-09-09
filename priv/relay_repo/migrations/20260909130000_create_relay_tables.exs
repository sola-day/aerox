defmodule Aerox.Relay.Repo.Migrations.CreateRelayTables do
  @moduledoc """
  The Relay's tables (DESIGN §19), mirroring indigo's relay models: `host`,
  `account` (+ the fast-changing `account_repo`), and the Relay's own
  `repo_seq` for re-sequenced output.
  """
  use Ecto.Migration

  def change do
    create table(:host) do
      add :hostname, :text, null: false
      add :no_ssl, :boolean, null: false, default: false
      add :account_limit, :bigint, null: false, default: 100
      add :trusted, :boolean, null: false, default: false
      # active | idle | offline | throttled | banned
      add :status, :text, null: false, default: "active"
      add :last_seq, :bigint, null: false, default: -1
      add :account_count, :bigint, null: false, default: 0
      add :error_count, :bigint, null: false, default: 0
      add :last_event_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:host, [:hostname])

    create table(:account, primary_key: false) do
      add :uid, :bigserial, primary_key: true
      add :did, :text, null: false
      add :host_id, :bigint, null: false
      # local status: active | host-throttled | takendown | suspended
      add :status, :text, null: false, default: "active"
      # what the host last told us: active | deactivated | takendown | suspended | deleted | ...
      add :upstream_status, :text, null: false, default: "active"
    end

    create unique_index(:account, [:did])
    create index(:account, [:host_id])

    create table(:account_repo, primary_key: false) do
      add :uid, :bigint, primary_key: true
      add :rev, :text, null: false
      add :commit_cid, :text, null: false
      add :commit_data_cid, :text, null: false
    end

    create table(:repo_seq, primary_key: false) do
      add :seq, :bigint, primary_key: true
      add :did, :text, null: false
      add :event_type, :text, null: false
      add :event, :binary, null: false
      add :invalidated, :boolean, null: false, default: false
      add :sequenced_at, :utc_datetime_usec, null: false
    end

    create index(:repo_seq, [:did])
    create index(:repo_seq, [:sequenced_at])

    create table(:domain_ban, primary_key: false) do
      add :domain, :text, primary_key: true
      timestamps(type: :utc_datetime_usec)
    end
  end
end
