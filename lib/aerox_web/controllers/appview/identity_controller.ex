defmodule AeroxWeb.AppView.IdentityController do
  @moduledoc """
  `com.atproto.identity.resolveHandle`, `resolveDid`, `resolveIdentity` and
  `refreshIdentity` on the AppView, through its identity cache
  (`AeroxWeb.IdentityResolution`). A refresh also drops the DID's cached
  entries, as an `#identity` event would.
  """
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  alias AeroxWeb.IdentityResolution
  alias AeroxWeb.XRPC.Error

  @cache Aerox.AppView.Identity

  def resolve_handle(conn, _) do
    params = params!(conn, "com.atproto.identity.resolveHandle")

    case Aerox.Identity.resolve_handle(@cache, String.downcase(params["handle"])) do
      {:ok, did} -> respond(conn, %{"did" => did})
      _ -> {:error, Error.invalid_request("Unable to resolve handle")}
    end
  end

  def resolve_did(conn, _) do
    params = params!(conn, "com.atproto.identity.resolveDid")

    with {:ok, doc} <- IdentityResolution.did_doc(@cache, params["did"]),
         do: respond(conn, %{"didDoc" => doc})
  end

  def resolve_identity(conn, _) do
    params = params!(conn, "com.atproto.identity.resolveIdentity")

    with {:ok, info} <- IdentityResolution.identity(@cache, params["identifier"], []),
         do: respond(conn, info)
  end

  def refresh_identity(conn, _) do
    input = input!(conn, "com.atproto.identity.refreshIdentity")
    identifier = input["identifier"]

    if String.starts_with?(identifier, "did:"), do: Aerox.Identity.invalidate(@cache, identifier)

    with {:ok, info} <- IdentityResolution.identity(@cache, identifier, force: true) do
      # the handle the AppView shows follows the refreshed document
      Aerox.AppView.Indexing.index_handle(info["did"], DateTime.utc_now())
      respond(conn, info)
    end
  end
end
