defmodule Aerox.PDS.ReservedKeys do
  @moduledoc """
  Signing keys reserved before an account exists (upstream
  `actorStore.reserveKeypair` / `getReservedKeypair` / `clearReservedKeypair`).
  Account migration needs the new PDS's signing key before `createAccount`
  so that the DID document can name it; `reserveSigningKey` hands one out,
  and `Aerox.PDS.Signup` uses it — looked up by the DID it was reserved for,
  or by the `did:key` the DID document names — and clears it.

  Reserving for a DID that already has a key returns the same key.
  """
  import Ecto.Query
  alias Aerox.ATProto.Crypto
  alias Aerox.PDS.Repo
  alias Aerox.PDS.Schema.ReservedSigningKey

  @doc "Reserves a K-256 key, for `did` when given; returns its `did:key`."
  @spec reserve(String.t() | nil) :: String.t()
  def reserve(did \\ nil) do
    case did && Repo.one(from(k in ReservedSigningKey, where: k.did == ^did)) do
      %ReservedSigningKey{key_did: key_did} ->
        key_did

      _ ->
        keypair = Crypto.generate(:k256)
        key_did = Crypto.did_key(keypair)

        Repo.insert_all(
          ReservedSigningKey,
          [
            %{
              key_did: key_did,
              did: did,
              private_key: keypair.private,
              created_at: DateTime.utc_now()
            }
          ],
          on_conflict: :nothing
        )

        # a concurrent reservation for the same DID won the unique index
        if did, do: reserve(did), else: key_did
    end
  end

  @doc "The reserved keypair for a DID or a `did:key`, or nil."
  @spec get(String.t() | nil) :: Crypto.Keypair.t() | nil
  def get(nil), do: nil

  def get(did_or_key) do
    from(k in ReservedSigningKey,
      where: k.key_did == ^did_or_key or k.did == ^did_or_key,
      select: k.private_key,
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> nil
      private -> Crypto.from_private(:k256, private)
    end
  end

  @doc "Forgets a reservation once its key is in use."
  def clear(key_did, did \\ nil) do
    Repo.delete_all(from(k in ReservedSigningKey, where: k.key_did == ^key_did))
    if did, do: Repo.delete_all(from(k in ReservedSigningKey, where: k.did == ^did))
    :ok
  end
end
