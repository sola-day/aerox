defmodule Aerox.PLC.Repo.Migrations.CreateOperations do
  @moduledoc """
  The did:plc directory's tables, mirroring did-method-plc's Postgres
  schema: `operations` (one row per submitted op, nullified flag, seq for
  the export cursor), `dids` (one row per DID, used as the row lock that
  serialises submissions), and `admin_logs` (removeInvalidOps audit,
  DESIGN §14.2 point 7).
  """
  use Ecto.Migration

  def change do
    create table(:dids, primary_key: false) do
      add :did, :text, primary_key: true
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    execute("CREATE SEQUENCE plc_seq_sequence", "DROP SEQUENCE plc_seq_sequence")

    create table(:operations, primary_key: false) do
      add :did, :text, null: false
      add :cid, :text, null: false
      add :operation, :map, null: false
      add :nullified, :boolean, null: false, default: false
      add :created_at, :utc_datetime_usec, null: false
      add :seq, :bigint, null: false, default: fragment("nextval('plc_seq_sequence')")
    end

    create unique_index(:operations, [:did, :cid], name: :operations_primary_key)
    create index(:operations, [:created_at])
    create index(:operations, [:did, :created_at])
    create unique_index(:operations, [:seq])

    create table(:admin_logs) do
      add :type, :text, null: false
      add :data, :map, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end
  end
end
