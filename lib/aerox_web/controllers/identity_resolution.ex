defmodule AeroxWeb.IdentityResolution do
  @moduledoc """
  `com.atproto.identity.resolveDid`, `resolveIdentity` and `refreshIdentity`,
  shared by the services that answer them (the PDS and the AppView), each
  through its own identity cache (DESIGN §20.1). Semantics and error names are
  indigo `bluepages`':

  * a DID resolves to its document; its handle is the declared one only if
    that handle resolves back to the DID, otherwise `handle.invalid`;
  * a handle resolves to a DID whose document must declare the same handle
    (`HandleMismatch` otherwise);
  * "not found" is a 404 (`DidNotFound`, `HandleNotFound`), a resolver that
    could not answer is a 502;
  * a refresh is the same resolution with the cache bypassed.
  """
  alias Aerox.ATProto.{Identity, Syntax}
  alias AeroxWeb.XRPC.Error

  @invalid "handle.invalid"

  @type opts :: [force: boolean, local_handle: (String.t() -> String.t() | nil)]

  @spec did_doc(atom, String.t(), opts) :: {:ok, map} | {:error, Error.t()}
  def did_doc(cache, did, opts \\ []) do
    case Aerox.Identity.resolve_did(cache, did, Keyword.take(opts, [:force])) do
      {:ok, doc} -> {:ok, doc}
      {:error, :not_found} -> {:error, Error.not_found("DID not found: #{did}", "DidNotFound")}
      {:error, reason} -> {:error, failure("DIDResolutionFailed", reason)}
    end
  end

  @doc "`identityInfo` for a DID or a handle."
  @spec identity(atom, String.t(), opts) :: {:ok, map} | {:error, Error.t()}
  def identity(cache, "did:" <> _ = did, opts) do
    with {:ok, doc} <- did_doc(cache, did, opts) do
      declared = doc |> Identity.handle() |> normalize()

      handle =
        with h when is_binary(h) <- declared,
             true <- Syntax.valid_handle?(h),
             {:ok, ^did} <- handle_did(cache, h, opts) do
          h
        else
          _ -> @invalid
        end

      {:ok, %{"did" => did, "handle" => handle, "didDoc" => doc}}
    end
  end

  def identity(cache, handle, opts) do
    handle = normalize(handle)

    with {:ok, did} <- handle_or_error(cache, handle, opts),
         {:ok, doc} <- did_doc(cache, did, opts) do
      if normalize(Identity.handle(doc)) == handle,
        do: {:ok, %{"did" => did, "handle" => handle, "didDoc" => doc}},
        else:
          {:error,
           Error.invalid_request(
             "DID document for #{did} does not declare the handle #{handle}",
             "HandleMismatch"
           )}
    end
  end

  defp handle_or_error(cache, handle, opts) do
    case handle_did(cache, handle, opts) do
      {:ok, did} ->
        {:ok, did}

      {:error, :not_found} ->
        {:error, Error.not_found("Handle not found: #{handle}", "HandleNotFound")}

      {:error, reason} ->
        {:error, failure("HandleResolutionFailed", reason)}
    end
  end

  defp handle_did(cache, handle, opts) do
    local = Keyword.get(opts, :local_handle, fn _ -> nil end)

    case local.(handle) do
      did when is_binary(did) -> {:ok, did}
      nil -> Aerox.Identity.resolve_handle(cache, handle, Keyword.take(opts, [:force]))
    end
  end

  defp normalize(nil), do: nil
  defp normalize(h), do: String.downcase(h)

  defp failure(name, reason),
    do: %Error{status: 502, name: name, message: "resolution failed: #{inspect(reason)}"}
end
