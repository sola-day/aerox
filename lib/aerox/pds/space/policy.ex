defmodule Aerox.PDS.Space.Policy do
  @moduledoc """
  The simplespace mint policies (DESIGN §12.5, `com.atproto.simplespace.defs`):
  a credential is minted only when the *user* passes `mintPolicy` —
  `member-list` (default; the host's member list), `public` (anyone) or
  `managing-app` (the app named by `managingApp` is asked over
  `com.atproto.simplespace.checkUserAccess` with service auth from the
  authority) — **and** the *app* passes `appAccess` — `#open` or `#allowList`
  (the attested `clientId` must be listed).
  """
  alias Aerox.PDS.Space.Spaces

  @check_lxm "com.atproto.simplespace.checkUserAccess"

  @doc "The user perimeter."
  @spec authorize_user(Spaces.space(), String.t(), String.t()) ::
          :ok | {:error, :user_not_authorized | :managing_app_unreachable}
  def authorize_user(space, user_did, client_id) do
    cond do
      space.is_public or space.mint_policy == "public" ->
        :ok

      space.mint_policy == "managing-app" and is_binary(space.managing_app) ->
        check_user_access(space, user_did, client_id)

      # member-list, and managing-app with no app configured
      Spaces.member?(space.did, space.uri, user_did) ->
        :ok

      true ->
        {:error, :user_not_authorized}
    end
  end

  @doc "The app perimeter."
  @spec authorize_app(Spaces.space(), String.t()) :: :ok | {:error, :app_not_authorized}
  def authorize_app(space, client_id) do
    case space.app_access_mode do
      "allowList" ->
        if client_id in space.app_exceptions, do: :ok, else: {:error, :app_not_authorized}

      # upstream's earlier allow/deny + exceptions model, kept readable
      "deny" ->
        if client_id in space.app_exceptions, do: :ok, else: {:error, :app_not_authorized}

      "allow" ->
        if client_id in space.app_exceptions, do: {:error, :app_not_authorized}, else: :ok

      _open ->
        :ok
    end
  end

  # `checkUserAccess` on the managing app: GET <endpoint>/xrpc/<lxm>?space&user[&clientId]
  # with a service JWT iss = the authority, aud = the managing app's service
  # identifier (what bulletin's `verifyManagingAppRequest` expects).
  defp check_user_access(space, user_did, client_id) do
    with {:ok, endpoint} <- Aerox.PDS.Space.Notify.resolve_service_endpoint(space.managing_app),
         %Aerox.ATProto.Crypto.Keypair{} = keypair <-
           Aerox.PDS.Accounts.signing_keypair(space.did) do
      jwt =
        Aerox.Auth.ServiceJWT.create(
          keypair: keypair,
          iss: space.did,
          aud: space.managing_app,
          lxm: @check_lxm
        )

      query =
        URI.encode_query(
          [{"space", space.uri}, {"user", user_did}] ++
            if(client_id && client_id != "unknown", do: [{"clientId", client_id}], else: [])
        )

      url = String.trim_trailing(endpoint, "/") <> "/xrpc/" <> @check_lxm <> "?" <> query

      case Aerox.Identity.HTTP.get(url, headers: [{"authorization", "Bearer " <> jwt}]) do
        {:ok, 200, _headers, body} ->
          case Jason.decode(body) do
            {:ok, %{"authorized" => true}} -> :ok
            _ -> {:error, :user_not_authorized}
          end

        {:ok, _status, _headers, _body} ->
          {:error, :user_not_authorized}

        {:error, _} ->
          {:error, :managing_app_unreachable}
      end
    else
      _ -> {:error, :managing_app_unreachable}
    end
  end
end
