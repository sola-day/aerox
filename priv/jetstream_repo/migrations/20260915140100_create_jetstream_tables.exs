defmodule Aerox.Jetstream.Repo.Migrations.CreateJetstreamTables do
  @moduledoc """
  Jetstream's durable state. Segment files on disk hold the archive; these
  tables hold what is not yet in a block and what the processes resume from:

  * `event` — rows appended but not yet flushed into a block (upstream's
    in-memory buffer ahead of the active segment, made durable), their `seq`
    from `event_seq`;
  * `bootstrap_live` — live rows captured while the bootstrap backfill runs,
    merged into the log afterwards (upstream's `backfill/live_segments`);
  * `state` — the relay cursor, the phase, the compaction watermark;
  * `repo` — per-repo backfill and resync bookkeeping (upstream `repo/<did>`);
  * `tombstone` — record and DID tombstones not yet compacted;
  * `timestamp_rule`, `import_job` — operator timestamp imports.
  """
  use Ecto.Migration

  def change do
    execute("CREATE SEQUENCE event_seq START 1", "DROP SEQUENCE event_seq")

    create table(:event, primary_key: false) do
      add :seq, :bigint, primary_key: true
      add :witnessed_at, :bigint, null: false
      add :indexed_at, :bigint, null: false, default: 0
      add :kind, :smallint, null: false
      add :did, :text, null: false
      add :collection, :text, null: false, default: ""
      add :rkey, :text, null: false, default: ""
      add :rev, :text, null: false, default: ""
      add :payload, :binary, null: false
    end

    create table(:bootstrap_live, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :kind, :smallint, null: false
      add :did, :text, null: false
      add :collection, :text, null: false, default: ""
      add :rkey, :text, null: false, default: ""
      add :rev, :text, null: false, default: ""
      add :payload, :binary, null: false
    end

    create table(:state, primary_key: false) do
      add :key, :text, primary_key: true
      add :value, :map, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create table(:repo, primary_key: false) do
      add :did, :text, primary_key: true
      add :status, :text, null: false
      add :pds, :text
      add :backfill_rev, :text
      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime_usec
      add :error, :text
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:repo, [:status, :next_attempt_at])

    create table(:tombstone, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :seq, :bigint, null: false
      # "uri" (a record's at-uri) or "did"
      add :scope, :text, null: false
      add :key, :text, null: false
    end

    create index(:tombstone, [:seq])

    create table(:timestamp_rule, primary_key: false) do
      add :uri, :text, primary_key: true
      # "" applies to every version
      add :cid, :text, primary_key: true
      add :indexed_at, :bigint, null: false
    end

    create table(:import_job, primary_key: false) do
      add :id, :text, primary_key: true
      add :path, :text, null: false
      add :state, :text, null: false
      add :phase, :text
      add :error, :text
      add :counters, :map, null: false, default: %{}
      add :submitted_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec
    end
  end
end
