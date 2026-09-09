defmodule Aerox.Labeler.Repo.Migrations.CreateLabelerTables do
  @moduledoc """
  The Labeler's tables (DESIGN §17): signed labels with their sequencer
  table (the §5 pattern: `label_seq` has `relay.repo_seq`'s shape and the
  stored `event` is the DAG-CBOR `#labels` body without `seq`), the report
  intake, the append-only moderation event log, and the settings the
  setup task persists (the labeler account's DID and signing key).
  """
  use Ecto.Migration

  def change do
    # ---- labels (§17.1) ---------------------------------------------------------
    # Upstream ozone's `label` table plus `ver` and the `seq` of the event that
    # carried the current row. One row per (src, uri, cid, val): a negation or
    # re-application replaces it (ozone's `createLabels` upsert), so
    # `queryLabels` answers with the current state and `id` is its cursor.
    create table(:label) do
      add :src, :text, null: false
      add :uri, :text, null: false
      add :cid, :text, null: false, default: ""
      add :val, :text, null: false
      add :neg, :boolean, null: false, default: false
      add :cts, :utc_datetime_usec, null: false
      add :exp, :utc_datetime_usec
      add :sig, :binary
      add :ver, :integer, null: false, default: 1
      add :seq, :bigint
    end

    create unique_index(:label, [:src, :uri, :cid, :val])
    create index(:label, [:uri])

    create table(:label_seq, primary_key: false) do
      add :seq, :bigserial, primary_key: true
      add :did, :text, null: false
      add :event_type, :text, null: false
      add :event, :binary, null: false
      add :invalidated, :boolean, null: false, default: false
      add :sequenced_at, :utc_datetime_usec, null: false
    end

    create index(:label_seq, [:sequenced_at])

    # ---- reports and the event log (§17.2) ------------------------------------
    create table(:mod_report) do
      add :subject, :map, null: false
      add :reason_type, :text, null: false
      add :reason, :text
      add :reported_by, :text, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create index(:mod_report, [:reported_by])
    create index(:mod_report, ["(subject->>'did')"])
    create index(:mod_report, ["(subject->>'uri')"])

    # Append-only: rows are inserted before the action is applied and never
    # updated except for `applied_at`, so a crash between the two leaves an
    # unapplied row `Aerox.Labeler.Actions.replay/0` completes.
    create table(:mod_event) do
      add :action, :text, null: false
      add :subject, :map, null: false
      add :created_by, :text, null: false
      add :comment, :text
      add :meta, :map, null: false, default: %{}
      add :created_at, :utc_datetime_usec, null: false
      add :applied_at, :utc_datetime_usec
    end

    create index(:mod_event, ["(subject->>'did')"])
    create index(:mod_event, ["(subject->>'uri')"])

    # ---- settings -------------------------------------------------------------
    create table(:setting, primary_key: false) do
      add :key, :text, primary_key: true
      add :value, :text, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end
  end
end
