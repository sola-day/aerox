defmodule Aerox.PDS.OAuth.Tokens do
  @moduledoc """
  Token issuance and verification (upstream `token-manager.ts`,
  `oauth-verifier.ts`). Access tokens are ES256 `at+jwt`s (jti = token id,
  sub, aud = the PDS service DID, cnf.jkt, scope, client_id, one hour);
  refresh tokens rotate on use and a replayed refresh token revokes the
  whole session. Session and refresh lifetimes follow upstream's constants
  (public clients: 2 weeks; confidential: 2 years / 3 months).
  """
  import Ecto.Query
  alias Aerox.PDS.OAuth.Keys
  alias Aerox.PDS.Repo
  alias Aerox.PDS.Schema.{OAuthToken, UsedRefreshToken}

  @token_max_age 60 * 60
  @public_session 14 * 24 * 3600
  @public_refresh @public_session
  @confidential_session 2 * 365 * 24 * 3600
  @confidential_refresh 90 * 24 * 3600

  defp gen(prefix, bytes),
    do: prefix <> Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)

  @doc "Issue a token set for an authorized request. `client` is `%Clients.Client{}`."
  def create(client, client_auth, did, device_id, params, code, issuer, aud) do
    token_id = gen("tok-", 16)
    refresh = if "refresh_token" in client.metadata["grant_types"], do: gen("ref-", 32)
    now = DateTime.utc_now()
    expires = DateTime.add(now, @token_max_age, :second)
    scope = params["scope"]

    Repo.insert!(%OAuthToken{
      did: did,
      token_id: token_id,
      created_at: now,
      updated_at: now,
      expires_at: expires,
      client_id: client.id,
      client_auth: client_auth,
      device_id: device_id,
      parameters: params,
      code: code,
      current_refresh_token: refresh,
      scope: scope
    })

    response(token_id, did, params, scope, now, expires, refresh, client.id, issuer, aud)
  end

  defp response(token_id, did, params, scope, now, expires, refresh, client_id, issuer, aud) do
    claims =
      %{
        "jti" => token_id,
        "sub" => did,
        "iat" => DateTime.to_unix(now),
        "exp" => DateTime.to_unix(expires),
        "aud" => aud,
        "iss" => issuer,
        "scope" => scope,
        "client_id" => client_id
      }
      |> then(
        &if(params["dpop_jkt"], do: Map.put(&1, "cnf", %{"jkt" => params["dpop_jkt"]}), else: &1)
      )

    access = Keys.sign(claims, "at+jwt")

    %{
      "access_token" => access,
      "token_type" => if(params["dpop_jkt"], do: "DPoP", else: "Bearer"),
      "refresh_token" => refresh,
      "scope" => scope,
      "expires_in" => DateTime.diff(expires, DateTime.utc_now()),
      "sub" => did
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc "Upstream consumeRefreshToken + rotateToken: a replay revokes the session."
  def refresh(refresh_token, client, client_auth, dpop, issuer, aud) do
    with {:ok, row} <- find_by_refresh(refresh_token),
         :ok <- compare_client_auth(row, client, client_auth, dpop),
         :ok <- check_lifetimes(row, client, client_auth) do
      new_id = gen("tok-", 16)
      new_refresh = gen("ref-", 32)
      now = DateTime.utc_now()
      expires = DateTime.add(now, @token_max_age, :second)

      Repo.transaction(fn ->
        Repo.insert!(%UsedRefreshToken{refresh_token: refresh_token, token_id: row.id})

        Repo.update_all(from(t in OAuthToken, where: t.id == ^row.id),
          set: [
            token_id: new_id,
            current_refresh_token: new_refresh,
            updated_at: now,
            expires_at: expires,
            client_auth: client_auth
          ]
        )
      end)

      {:ok,
       response(
         new_id,
         row.did,
         row.parameters,
         row.scope,
         now,
         expires,
         new_refresh,
         row.client_id,
         issuer,
         aud
       )}
    end
  end

  defp find_by_refresh(refresh_token) do
    case Repo.get_by(OAuthToken, current_refresh_token: refresh_token) do
      %OAuthToken{} = row ->
        {:ok, row}

      nil ->
        # a used refresh token means replay: revoke the session it belonged to
        case Repo.get(UsedRefreshToken, refresh_token) do
          %{token_id: id} ->
            Repo.delete_all(from(t in OAuthToken, where: t.id == ^id))
            Repo.delete_all(from(u in UsedRefreshToken, where: u.token_id == ^id))
            {:error, {:invalid_grant, "Refresh token replayed"}}

          nil ->
            {:error, {:invalid_grant, "Invalid refresh token"}}
        end
    end
  end

  @doc "Upstream compareClientAuth."
  def compare_client_auth(row, client, client_auth, dpop) do
    initial = row.client_auth || %{}
    params = row.parameters

    cond do
      client_auth["method"] != client.metadata["token_endpoint_auth_method"] ->
        {:error,
         {:invalid_grant,
          "Client authentication method mismatch (expected #{client.metadata["token_endpoint_auth_method"]}, got #{client_auth["method"]})"}}

      row.client_id != client.id ->
        {:error, {:invalid_grant, "Token was not issued to this client"}}

      params["dpop_jkt"] && is_nil(dpop) ->
        {:error, {:invalid_grant, "DPoP proof is required for this request"}}

      params["dpop_jkt"] && params["dpop_jkt"] != dpop.jkt ->
        {:error, {:invalid_grant, "DPoP proof does not match the expected JKT"}}

      initial["method"] == "private_key_jwt" and
          (client_auth["method"] != "private_key_jwt" or client_auth["kid"] != initial["kid"] or
             client_auth["alg"] != initial["alg"] or client_auth["jkt"] != initial["jkt"]) ->
        {:error,
         {:invalid_grant,
          "The session was initiated with a different key than the client assertion currently used"}}

      true ->
        :ok
    end
  end

  defp check_lifetimes(row, client, client_auth) do
    {session, refresh} =
      if client_auth["method"] != "none" or client.trusted,
        do: {@confidential_session, @confidential_refresh},
        else: {@public_session, @public_refresh}

    now = DateTime.utc_now()

    cond do
      DateTime.diff(now, row.created_at) > session ->
        {:error, {:invalid_grant, "Session expired"}}

      DateTime.diff(now, row.updated_at) > refresh ->
        {:error, {:invalid_grant, "Refresh token expired"}}

      true ->
        :ok
    end
  end

  @doc "Find by access-token id (jti), refresh token or code (upstream findToken for revocation)."
  def find(token) do
    cond do
      String.starts_with?(token, "ref-") ->
        Repo.get_by(OAuthToken, current_refresh_token: token)

      String.starts_with?(token, "cod-") ->
        Repo.get_by(OAuthToken, code: token)

      true ->
        case Keys.verify(token) do
          {:ok, _, %{"jti" => jti}} -> Repo.get_by(OAuthToken, token_id: jti)
          _ -> Repo.get_by(OAuthToken, token_id: token)
        end
    end
  end

  def delete(id) do
    Repo.delete_all(from(t in OAuthToken, where: t.id == ^id))
    Repo.delete_all(from(u in UsedRefreshToken, where: u.token_id == ^id))
    :ok
  end

  def delete_by_code(code) do
    case Repo.get_by(OAuthToken, code: code) do
      nil -> :ok
      row -> delete(row.id)
    end
  end

  def list_for_did(did),
    do:
      Repo.all(from(t in OAuthToken, where: t.did == ^did and t.expires_at > ^DateTime.utc_now()))

  def revoke_all(did) do
    ids = Repo.all(from(t in OAuthToken, where: t.did == ^did, select: t.id))
    Repo.delete_all(from(u in UsedRefreshToken, where: u.token_id in ^ids))
    Repo.delete_all(from(t in OAuthToken, where: t.did == ^did))
    :ok
  end

  # ---------------------------------------------------------- verification

  @doc """
  Resource-server side (upstream OAuthVerifier.authenticateRequest): the
  token type from the `authorization` scheme (`DPoP` or `Bearer`), the JWT
  signature, `typ`, expiry, `aud`, the `atproto` scope, and the DPoP key
  binding. Returns `{:ok, %{did, scope, client_id, token_id}}`.
  """
  def verify_access(token, token_type, dpop, aud) do
    with {:ok, %{"typ" => "at+jwt"}, claims} <- verify_typed(token),
         :ok <- check_exp(claims),
         :ok <-
           if(claims["aud"] == aud, do: :ok, else: {:error, {:invalid_token, "Invalid audience"}}),
         :ok <- check_binding(claims, token_type, dpop),
         :ok <-
           if("atproto" in String.split(claims["scope"] || "", " "),
             do: :ok,
             else: {:error, {:invalid_token, "OAuth token does not have \"atproto\" scope"}}
           ),
         {:ok, row} <- live_row(claims["jti"], claims) do
      {:ok,
       %{
         did: claims["sub"],
         scope: row.scope || claims["scope"],
         client_id: claims["client_id"],
         token_id: claims["jti"]
       }}
    else
      {:ok, _, _} -> {:error, {:invalid_token, "Malformed token"}}
      {:error, :invalid_signature} -> {:error, {:invalid_token, "Malformed token"}}
      {:error, _} = e -> e
    end
  end

  defp verify_typed(token) do
    case Keys.verify(token) do
      {:ok, header, claims} -> {:ok, header, claims}
      e -> e
    end
  end

  defp check_exp(%{"exp" => exp}) when is_integer(exp) do
    if exp > System.os_time(:second), do: :ok, else: {:error, {:invalid_token, "Token expired"}}
  end

  defp check_exp(_), do: {:error, {:invalid_token, "Malformed token"}}

  defp check_binding(%{"cnf" => %{"jkt" => jkt}}, token_type, dpop) do
    cond do
      token_type != "DPoP" ->
        {:error,
         {:invalid_token,
          "Access token is bound to a DPoP proof, but token type is #{token_type}"}}

      is_nil(dpop) ->
        {:error, {:invalid_dpop_proof, "DPoP proof required"}}

      jkt != dpop.jkt ->
        {:error, {:invalid_dpop_proof, "DPoP key binding mismatch"}}

      true ->
        :ok
    end
  end

  defp check_binding(_, "Bearer", _), do: :ok

  defp check_binding(_, _, _),
    do: {:error, {:invalid_token, "Bearer token type must be used without a DPoP proof"}}

  # stateful check (upstream AccessTokenMode.stateful): the token row must exist and match
  defp live_row(jti, claims) do
    case Repo.get_by(OAuthToken, token_id: jti) do
      nil ->
        {:error, {:invalid_token, "Invalid token"}}

      row ->
        if get_in(claims, ["cnf", "jkt"]) != row.parameters["dpop_jkt"],
          do:
            (
              delete(row.id)
              {:error, {:invalid_token, "Invalid token"}}
            ),
          else: {:ok, row}
    end
  end
end
