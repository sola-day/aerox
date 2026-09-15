defmodule Aerox.PDS.Repo.Migrations.CreateTempMethodTables do
  @moduledoc """
  State behind the `com.atproto.temp.*` methods: handles an operator has
  reserved (`addReservedHandle`), outstanding phone verification codes
  (`requestPhoneVerification`, checked by `createAccount`), and OAuth scope
  references (`dereferenceScope`: an access token whose scope is too long to
  carry inline names it as `ref:<cid>`).
  """
  use Ecto.Migration

  def change do
    create table(:reserved_handle, primary_key: false) do
      add :handle, :text, primary_key: true
      add :created_at, :utc_datetime_usec, null: false
    end

    create table(:phone_verification, primary_key: false) do
      add :phone, :text, primary_key: true
      add :code_hash, :binary, null: false
      add :attempts, :integer, null: false, default: 0
      add :expires_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create table(:oauth_scope_ref, primary_key: false) do
      add :ref, :text, primary_key: true
      add :scope, :text, null: false
      add :created_at, :utc_datetime_usec, null: false
    end
  end
end
