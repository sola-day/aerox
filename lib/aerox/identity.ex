defmodule Aerox.Identity do
  @moduledoc """
  Band 2: the impure half of DESIGN §3.0 — DID and handle *resolution* with a
  cache (DESIGN §20.1). Parsing stays in the kernel.
  """
  use Boundary, top_level?: true, deps: [Aerox.ATProto], exports: :all

  alias Aerox.Identity.Cache

  @doc "DID document through a service's cache."
  defdelegate resolve_did(cache, did, opts \\ []), to: Cache

  @doc "Handle → DID through a service's cache."
  defdelegate resolve_handle(cache, handle, opts \\ []), to: Cache

  @doc "Invalidate a DID's entries on an `#identity` event."
  defdelegate invalidate(cache, did), to: Cache

  @doc "The signing `did:key` for a DID (`did:key` inputs pass through), as upstream `resolveAtprotoKey`."
  @spec resolve_signing_key(atom, String.t(), keyword) :: {:ok, String.t()} | {:error, term}
  def resolve_signing_key(_cache, "did:key:" <> _ = did_key, _opts), do: {:ok, did_key}

  def resolve_signing_key(cache, did, opts) do
    with {:ok, doc} <- Cache.resolve_did(cache, did, opts) do
      case Aerox.ATProto.Identity.signing_did_key(doc) do
        {:ok, key} -> {:ok, key}
        :error -> {:error, :no_signing_key}
      end
    end
  end
end
