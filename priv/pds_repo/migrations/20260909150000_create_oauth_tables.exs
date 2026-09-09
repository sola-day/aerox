defmodule Aerox.PDS.Repo.Migrations.CreateOauthTables do
  @moduledoc "OAuth authorization-server storage (DESIGN §11.2), upstream account-manager tables one-to-one."
  use Ecto.Migration

  def change do
    create table(:device, primary_key: false) do
      add :id, :text, primary_key: true
      add :session_id, :text, null: false
      add :user_agent, :text
      add :ip_address, :text, null: false
      add :last_seen_at, :utc_datetime_usec, null: false
    end

    create unique_index(:device, [:session_id])

    create table(:account_device, primary_key: false) do
      add :did, :text, primary_key: true
      add :device_id, :text, primary_key: true
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:account_device, [:device_id])

    create table(:authorization_request, primary_key: false) do
      add :id, :text, primary_key: true
      add :did, :text
      add :device_id, :text
      add :client_id, :text, null: false
      add :client_auth, :map
      add :parameters, :map, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :code, :text
    end

    create unique_index(:authorization_request, [:code])
    create index(:authorization_request, [:expires_at])

    create table(:oauth_token) do
      add :did, :text, null: false
      add :token_id, :text, null: false
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :client_id, :text, null: false
      add :client_auth, :map, null: false
      add :device_id, :text
      add :parameters, :map, null: false
      add :details, :map
      add :code, :text
      add :current_refresh_token, :text
      add :scope, :text
    end

    create unique_index(:oauth_token, [:token_id])
    create unique_index(:oauth_token, [:current_refresh_token])
    create unique_index(:oauth_token, [:code])
    create index(:oauth_token, [:did])

    create table(:used_refresh_token, primary_key: false) do
      add :refresh_token, :text, primary_key: true
      add :token_id, :bigint, null: false
    end

    create index(:used_refresh_token, [:token_id])

    create table(:authorized_client, primary_key: false) do
      add :did, :text, primary_key: true
      add :client_id, :text, primary_key: true
      add :created_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
      add :data, :map, null: false
    end
  end
end
