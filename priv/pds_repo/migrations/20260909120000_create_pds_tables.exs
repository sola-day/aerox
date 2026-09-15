defmodule Aerox.PDS.Repo.Migrations.CreatePdsTables do
  @moduledoc """
  The PDS's tables (DESIGN §4.2, §4.7, §18.3): upstream's per-account
  `store.sqlite` tables each gaining a `did` column and a composite key, the
  central `account.sqlite` tables one-to-one, the sequencer's `repo_seq`,
  and the PLC signing audit (§14.2). Foreign keys from `did` cascade so an
  account deletion is one statement per root table.
  """
  use Ecto.Migration

  def change do
    # ---- central (upstream account.sqlite) ------------------------------
    create table(:actor, primary_key: false) do
      add :did, :text, primary_key: true
      add :handle, :text
      add :signing_key, :binary, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :takedown_ref, :text
      add :deactivated_at, :utc_datetime_usec
      add :delete_after, :utc_datetime_usec
    end

    create unique_index(:actor, [:handle])
    create index(:actor, [:created_at, :did])

    create table(:account, primary_key: false) do
      add :did, references(:actor, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :email, :text, null: false
      add :password_scrypt, :text, null: false
      add :email_confirmed_at, :utc_datetime_usec
      add :invites_disabled, :boolean, null: false, default: false
    end

    create unique_index(:account, [:email])

    create table(:refresh_token, primary_key: false) do
      add :id, :text, primary_key: true
      add :did, references(:actor, column: :did, type: :text, on_delete: :delete_all), null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :app_password_name, :text
      add :next_id, :text
    end

    create index(:refresh_token, [:did])

    create table(:app_password, primary_key: false) do
      add :did, references(:actor, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :name, :text, primary_key: true
      add :password_scrypt, :text, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :privileged, :boolean, null: false, default: false
    end

    create table(:invite_code, primary_key: false) do
      add :code, :text, primary_key: true
      add :available_uses, :integer, null: false
      add :disabled, :boolean, null: false, default: false
      add :for_account, :text, null: false
      add :created_by, :text, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create index(:invite_code, [:for_account])

    create table(:invite_code_use, primary_key: false) do
      add :code, :text, primary_key: true
      add :used_by, :text, primary_key: true
      add :used_at, :utc_datetime_usec, null: false
    end

    create table(:email_token, primary_key: false) do
      add :purpose, :text, primary_key: true

      add :did, references(:actor, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :token, :text, null: false
      add :requested_at, :utc_datetime_usec, null: false
    end

    create unique_index(:email_token, [:purpose, :token])

    # ---- per-account repo (upstream store.sqlite) -----------------------
    create table(:repo_root, primary_key: false) do
      add :did, references(:actor, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :cid, :text, null: false
      add :rev, :text, null: false
      add :indexed_at, :utc_datetime_usec, null: false
    end

    create table(:repo_block, primary_key: false) do
      add :did, references(:actor, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :cid, :text, primary_key: true
      add :rev, :text, null: false
      add :size, :integer, null: false
      add :content, :binary, null: false
    end

    create index(:repo_block, [:did, :rev])

    create table(:record, primary_key: false) do
      add :did, references(:actor, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :collection, :text, primary_key: true
      add :rkey, :text, primary_key: true
      add :uri, :text, null: false
      add :cid, :text, null: false
      add :rev, :text, null: false
      add :indexed_at, :utc_datetime_usec, null: false
      add :takedown_ref, :text
    end

    create unique_index(:record, [:uri])
    create index(:record, [:did, :cid])
    create index(:record, [:did, :rev])

    create table(:backlink, primary_key: false) do
      add :did, references(:actor, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :uri, :text, primary_key: true
      add :path, :text, primary_key: true
      add :link_to, :text, null: false
    end

    create index(:backlink, [:did, :path, :link_to])

    create table(:blob, primary_key: false) do
      add :did, references(:actor, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :cid, :text, primary_key: true
      add :mime_type, :text, null: false
      add :size, :bigint, null: false
      add :temp_key, :text
      add :created_at, :utc_datetime_usec, null: false
      add :takedown_ref, :text
    end

    create table(:record_blob, primary_key: false) do
      add :did, references(:actor, column: :did, type: :text, on_delete: :delete_all),
        primary_key: true

      add :blob_cid, :text, primary_key: true
      add :record_uri, :text, primary_key: true
    end

    create index(:record_blob, [:did, :record_uri])

    create table(:account_pref) do
      add :did, references(:actor, column: :did, type: :text, on_delete: :delete_all), null: false
      add :name, :text, null: false
      add :value, :map, null: false
    end

    create index(:account_pref, [:did])

    # ---- sequencer (DESIGN §4.7) ----------------------------------------
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

    # ---- PLC signing audit (DESIGN §14.2 point 5) -----------------------
    create table(:plc_op_audit) do
      add :did, :text, null: false
      add :cid, :text, null: false
      add :purpose, :text, null: false
      add :actor, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    create index(:plc_op_audit, [:did])
  end
end
