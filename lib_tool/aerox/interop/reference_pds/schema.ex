defmodule Aerox.Interop.ReferencePds.Schema do
  @moduledoc """
  The reference PDS's SQLite DDL and Kysely migration names, **pinned per
  upstream image version** (DESIGN §13.2: each file carries a
  `kysely_migration` table whose rows must match the target version's
  migration list, or the PDS re-migrates and fails).

  `"0.4"` is `ghcr.io/bluesky-social/pds:0.4` (bundles `@atproto/pds`
  0.5.27); the DDL below was read back from that image's own files
  (`test/golden/interop/ref-pds-0.4/`, `sqlite_master`). Upstream source:
  `packages/pds/src/{account-manager,actor-store,sequencer}/db/migrations`.
  """

  @account_ddl [
    ~s|CREATE TABLE "account" ("did" varchar primary key, "email" varchar not null, "passwordScrypt" varchar not null, "emailConfirmedAt" varchar, "invitesDisabled" int2 default 0 not null)|,
    ~s|CREATE UNIQUE INDEX "account_email_lower_idx" on "account" (lower("email"))|,
    ~s|CREATE TABLE "actor" ("did" varchar primary key, "handle" varchar, "createdAt" varchar not null, "takedownRef" varchar, "deactivatedAt" varchar, "deleteAfter" varchar)|,
    ~s|CREATE UNIQUE INDEX "actor_handle_lower_idx" on "actor" (lower("handle"))|,
    ~s|CREATE INDEX "actor_cursor_idx" on "actor" ("createdAt", "did")|,
    ~s|CREATE TABLE "app_password" ("did" varchar not null, "name" varchar not null, "passwordScrypt" varchar not null, "createdAt" varchar not null, "privileged" integer default 0 not null, constraint "app_password_pkey" primary key ("did", "name"))|,
    ~s|CREATE TABLE "device" ("id" varchar primary key, "sessionId" varchar not null, "userAgent" varchar, "ipAddress" varchar not null, "lastSeenAt" varchar not null, constraint "device_session_id_idx" unique ("sessionId"))|,
    ~s|CREATE TABLE "account_device" ("did" varchar not null, "deviceId" varchar not null, "createdAt" varchar not null, "updatedAt" varchar not null, constraint "account_device_pk" primary key ("deviceId", "did"), constraint "account_device_did_fk" foreign key ("did") references "account" ("did") on delete cascade on update cascade, constraint "account_device_device_id_fk" foreign key ("deviceId") references "device" ("id") on delete cascade on update cascade)|,
    ~s|CREATE INDEX "account_device_did_idx" on "account_device" ("did")|,
    ~s|CREATE TABLE "authorization_request" ("id" varchar primary key, "did" varchar, "deviceId" varchar, "clientId" varchar not null, "clientAuth" varchar not null, "parameters" varchar not null, "expiresAt" varchar not null, "code" varchar)|,
    ~s|CREATE UNIQUE INDEX "authorization_request_code_idx" on "authorization_request" (code DESC) WHERE (code IS NOT NULL)|,
    ~s|CREATE INDEX "authorization_request_expires_at_idx" on "authorization_request" ("expiresAt")|,
    ~s|CREATE TABLE "authorized_client" ("did" varchar not null, "clientId" varchar not null, "createdAt" varchar not null, "updatedAt" varchar not null, "data" varchar not null, constraint "authorized_client_pk" primary key ("did", "clientId"), constraint "authorized_client_did_fk" foreign key ("did") references "account" ("did") on delete cascade on update cascade)|,
    ~s|CREATE TABLE "device_account" ("did" varchar not null, "deviceId" varchar not null, "authenticatedAt" varchar not null, "remember" boolean not null, "authorizedClients" varchar not null, constraint "device_account_pk" primary key ("deviceId", "did"), constraint "device_account_device_id_fk" foreign key ("deviceId") references "device" ("id") on delete cascade on update cascade)|,
    ~s|CREATE TABLE "email_token" ("purpose" varchar not null, "did" varchar not null, "token" varchar not null, "requestedAt" varchar not null, constraint "email_token_pkey" primary key ("purpose", "did"), constraint "email_token_purpose_token_unique" unique ("purpose", "token"))|,
    ~s|CREATE TABLE "invite_code" ("code" varchar primary key, "availableUses" integer not null, "disabled" int2 default 0, "forAccount" varchar not null, "createdBy" varchar not null, "createdAt" varchar not null)|,
    ~s|CREATE INDEX "invite_code_for_account_idx" on "invite_code" ("forAccount")|,
    ~s|CREATE TABLE "invite_code_use" ("code" varchar not null, "usedBy" varchar not null, "usedAt" varchar not null, constraint "invite_code_use_pkey" primary key ("code", "usedBy"))|,
    ~s|CREATE TABLE "lexicon" ("nsid" varchar primary key, "createdAt" varchar not null, "updatedAt" varchar not null, "lastSucceededAt" varchar, "uri" varchar, "lexicon" varchar)|,
    ~s|CREATE INDEX "lexicon_failures_idx" on "lexicon" ("updatedAt" DESC) WHERE ("lexicon" is NULL)|,
    ~s|CREATE TABLE "refresh_token" ("id" varchar primary key, "did" varchar not null, "expiresAt" varchar not null, "nextId" varchar, "appPasswordName" varchar)|,
    ~s|CREATE INDEX "refresh_token_did_idx" on "refresh_token" ("did")|,
    ~s|CREATE TABLE "repo_root" ("did" varchar primary key, "cid" varchar not null, "rev" varchar not null, "indexedAt" varchar not null)|,
    ~s|CREATE TABLE "token" ("id" integer primary key autoincrement, "did" varchar not null, "tokenId" varchar not null, "createdAt" varchar not null, "updatedAt" varchar not null, "expiresAt" varchar not null, "clientId" varchar not null, "clientAuth" varchar not null, "deviceId" varchar, "parameters" varchar not null, "details" varchar, "code" varchar, "currentRefreshToken" varchar, "scope" varchar, constraint "token_current_refresh_token_unique_idx" unique ("currentRefreshToken"), constraint "token_id_unique_idx" unique ("tokenId"))|,
    ~s|CREATE UNIQUE INDEX "token_code_idx" on "token" (code DESC) WHERE (code IS NOT NULL)|,
    ~s|CREATE INDEX "token_did_idx" on "token" ("did")|,
    ~s|CREATE TABLE "used_refresh_token" ("refreshToken" varchar primary key, "tokenId" integer not null, constraint "used_refresh_token_fk" foreign key ("tokenId") references "token" ("id") on delete cascade on update cascade)|,
    ~s|CREATE INDEX "used_refresh_token_id_idx" on "used_refresh_token" ("tokenId")|
  ]

  @sequencer_ddl [
    ~s|CREATE TABLE "repo_seq" ("seq" integer primary key autoincrement, "did" varchar not null, "eventType" varchar not null, "event" blob not null, "invalidated" int2 default 0 not null, "sequencedAt" varchar not null)|,
    ~s|CREATE INDEX "repo_seq_did_idx" on "repo_seq" ("did")|,
    ~s|CREATE INDEX "repo_seq_event_type_idx" on "repo_seq" ("eventType")|,
    ~s|CREATE INDEX "repo_seq_sequenced_at_index" on "repo_seq" ("sequencedAt")|
  ]

  @actor_ddl [
    ~s|CREATE TABLE "repo_root" ("did" varchar primary key, "cid" varchar not null, "rev" varchar not null, "indexedAt" varchar not null)|,
    ~s|CREATE TABLE "repo_block" ("cid" varchar primary key, "repoRev" varchar not null, "size" integer not null, "content" blob not null)|,
    ~s|CREATE INDEX "repo_block_repo_rev_idx" on "repo_block" ("repoRev", "cid")|,
    ~s|CREATE TABLE "record" ("uri" varchar primary key, "cid" varchar not null, "collection" varchar not null, "rkey" varchar not null, "repoRev" varchar not null, "indexedAt" varchar not null, "takedownRef" varchar)|,
    ~s|CREATE INDEX "record_cid_idx" on "record" ("cid")|,
    ~s|CREATE INDEX "record_collection_idx" on "record" ("collection")|,
    ~s|CREATE INDEX "record_repo_rev_idx" on "record" ("repoRev")|,
    ~s|CREATE TABLE "blob" ("cid" varchar primary key, "mimeType" varchar not null, "size" integer not null, "tempKey" varchar, "width" integer, "height" integer, "createdAt" varchar not null, "takedownRef" varchar)|,
    ~s|CREATE INDEX "blob_tempkey_idx" on "blob" ("tempKey")|,
    ~s|CREATE TABLE "record_blob" ("blobCid" varchar not null, "recordUri" varchar not null, constraint "record_blob_pkey" primary key ("blobCid", "recordUri"))|,
    ~s|CREATE TABLE "backlink" ("uri" varchar not null, "path" varchar not null, "linkTo" varchar not null, constraint "backlinks_pkey" primary key ("uri", "path"))|,
    ~s|CREATE INDEX "backlink_link_to_idx" on "backlink" ("path", "linkTo")|,
    ~s|CREATE TABLE "account_pref" ("id" integer primary key autoincrement, "name" varchar not null, "valueJson" text not null)|
  ]

  @kysely_ddl [
    ~s|CREATE TABLE "kysely_migration" ("name" varchar(255) not null primary key, "timestamp" varchar(255) not null)|,
    ~s|CREATE TABLE "kysely_migration_lock" ("id" varchar(255) not null primary key, "is_locked" integer default 0 not null)|
  ]

  @versions %{
    "0.4" => %{
      package: "@atproto/pds 0.5.27",
      account: %{ddl: @account_ddl, migrations: ~w(001 002 003 004 005 006 007)},
      sequencer: %{ddl: @sequencer_ddl, migrations: ~w(001)},
      actor: %{ddl: @actor_ddl, migrations: ~w(001)}
    }
  }

  @doc "The pinned upstream versions this exporter can write."
  @spec versions() :: [String.t()]
  def versions, do: Map.keys(@versions)

  @doc "DDL statements and migration names for one database of one version."
  @spec for(String.t(), :account | :sequencer | :actor) ::
          {:ok, %{ddl: [String.t()], migrations: [String.t()]}} | {:error, term}
  def for(version, db) do
    case @versions do
      %{^version => %{^db => spec}} -> {:ok, spec}
      _ -> {:error, {:unsupported_pds_version, version, versions()}}
    end
  end

  @doc "The `kysely_migration*` DDL, common to every database."
  def kysely_ddl, do: @kysely_ddl
end
