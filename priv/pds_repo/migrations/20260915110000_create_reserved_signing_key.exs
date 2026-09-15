defmodule Aerox.PDS.Repo.Migrations.CreateReservedSigningKey do
  @moduledoc """
  `com.atproto.server.reserveSigningKey` (upstream `actorStore.reserveKeypair`):
  a signing key minted ahead of `createAccount`, so a DID document can be
  pointed at it before the account exists here — the account-migration step
  that needs the new PDS's key. Keyed by the key's `did:key`, and by the DID
  it was reserved for when one was given.
  """
  use Ecto.Migration

  def change do
    create table(:reserved_signing_key, primary_key: false) do
      add :key_did, :text, primary_key: true
      add :did, :text
      add :private_key, :binary, null: false
      add :created_at, :utc_datetime_usec, null: false
    end

    create unique_index(:reserved_signing_key, [:did], where: "did IS NOT NULL")
  end
end
