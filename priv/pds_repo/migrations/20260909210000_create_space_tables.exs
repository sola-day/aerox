defmodule Aerox.PDS.Repo.Migrations.CreateSpaceTables do
  @moduledoc """
  DESIGN §12.3: permissioned repos (Spaces, proposal 0016) live in their own
  tables, never in `repo_seq`. Mirrors the upstream `permissioned-data`
  actor-store schemas (`space*.ts`, migrations 002–004) with `did` — the
  account — added to every table, since every account shares one Postgres
  (DESIGN §4.2). Two tables beyond the branch: `space_notify_registration`
  (`registerNotify` by service identifier, as the alpha lexicon has it) and
  `space_writer` (the space host's writer set for `listRepos`).
  """
  use Ecto.Migration

  def change do
    # one row per (account, space): the account's view of a space it owns,
    # is a member of, or has written to
    create table(:space, primary_key: false) do
      add :did, :text, primary_key: true
      add :uri, :text, primary_key: true
      add :is_owner, :boolean, null: false, default: false
      add :is_member, :boolean, null: false, default: false
      add :mint_policy, :text, null: false, default: "member-list"
      add :managing_app, :text
      add :is_public, :boolean, null: false, default: false
      add :app_access_mode, :text, null: false, default: "open"
      add :app_exceptions, :jsonb, null: false, default: "[]"
      add :created_at, :utc_datetime_usec, null: false
      add :deleted_at, :utc_datetime_usec
    end

    # the account's permissioned repo in a space: LtHash state + rev
    create table(:space_repo, primary_key: false) do
      add :did, :text, primary_key: true
      add :space, :text, primary_key: true
      add :set_hash, :binary
      add :rev, :text
    end

    create table(:space_record, primary_key: false) do
      add :did, :text, primary_key: true
      add :space, :text, primary_key: true
      add :collection, :text, primary_key: true
      add :rkey, :text, primary_key: true
      add :cid, :text, null: false
      add :value, :binary, null: false
      add :repo_rev, :text, null: false
      add :indexed_at, :utc_datetime_usec, null: false
    end

    create table(:space_record_oplog, primary_key: false) do
      add :did, :text, primary_key: true
      add :space, :text, primary_key: true
      add :rev, :text, primary_key: true
      add :idx, :integer, primary_key: true
      add :action, :text, null: false
      add :collection, :text, null: false
      add :rkey, :text, null: false
      add :cid, :text
      add :prev, :text
    end

    # the space host's member list (owner-side)
    create table(:space_member, primary_key: false) do
      add :did, :text, primary_key: true
      add :space, :text, primary_key: true
      add :member_did, :text, primary_key: true
      add :member_rev, :text, null: false, default: ""
    end

    create table(:space_member_state, primary_key: false) do
      add :did, :text, primary_key: true
      add :space, :text, primary_key: true
      add :set_hash, :binary
      add :rev, :text
    end

    create table(:space_member_oplog, primary_key: false) do
      add :did, :text, primary_key: true
      add :space, :text, primary_key: true
      add :rev, :text, primary_key: true
      add :idx, :integer, primary_key: true
      add :action, :text, null: false
      add :member_did, :text, null: false
    end

    create table(:space_credential_recipient, primary_key: false) do
      add :did, :text, primary_key: true
      add :space, :text, primary_key: true
      add :service_did, :text, primary_key: true
      add :service_endpoint, :text, null: false
      add :last_issued_at, :utc_datetime_usec, null: false
    end

    # registerNotify: subscribers to a space's writes (space host)
    create table(:space_notify_registration, primary_key: false) do
      add :did, :text, primary_key: true
      add :space, :text, primary_key: true
      add :service, :text, primary_key: true
      add :endpoint, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    # listRepos: the writer set as claimed by notifyWrite (space host)
    create table(:space_writer, primary_key: false) do
      add :did, :text, primary_key: true
      add :space, :text, primary_key: true
      add :writer_did, :text, primary_key: true
      add :rev, :text, null: false
      add :hash, :binary
      add :updated_at, :utc_datetime_usec, null: false
    end
  end
end
