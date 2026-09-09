defmodule Aerox.PDS.Sessions do
  @moduledoc """
  Legacy sessions (DESIGN §11.2, upstream `account-manager/helpers/auth.ts`):
  HS256 JWTs with `typ: at+jwt` (access, 2 h) and `typ: refresh+jwt`
  (refresh, 90 d, `jti` stored in `refresh_token`), `aud` = the service DID,
  `sub` = the account DID, `scope` from upstream's `AuthScope` set. Refresh
  rotation keeps the old token usable for a 2-hour grace period via
  `next_id`, so a concurrent refresh returns the same successor.
  """
  import Ecto.Query
  alias Aerox.PDS.{Config, Repo}
  alias Aerox.PDS.Schema.{AppPassword, RefreshToken}

  @access_ttl 120 * 60
  @refresh_ttl 90 * 24 * 3600
  @grace 2 * 3600

  @scopes %{
    access: "com.atproto.access",
    refresh: "com.atproto.refresh",
    app_pass: "com.atproto.appPass",
    app_pass_privileged: "com.atproto.appPassPrivileged",
    signup_queued: "com.atproto.signupQueued",
    takendown: "com.atproto.takendown"
  }

  @type scope ::
          :access | :refresh | :app_pass | :app_pass_privileged | :signup_queued | :takendown

  def scope_string(scope), do: Map.fetch!(@scopes, scope)

  def scope_atom(str) do
    Enum.find_value(@scopes, fn {k, v} -> if v == str, do: k end)
  end

  @doc "`ACCESS_FULL`, `ACCESS_PRIVILEGED`, `ACCESS_STANDARD` from upstream's auth-scope.ts."
  def access_full, do: [:access]
  def access_privileged, do: [:access, :app_pass_privileged]
  def access_standard, do: [:access, :app_pass_privileged, :app_pass]

  @doc "The scope a session gets (upstream `formatScope`)."
  @spec scope_for(map | nil, boolean) :: scope
  def scope_for(_app_password, true), do: :takendown
  def scope_for(nil, _), do: :access
  def scope_for(%{privileged: true}, _), do: :app_pass_privileged
  def scope_for(%{}, _), do: :app_pass

  defp jwk, do: JOSE.JWK.from_oct(Config.jwt_secret())

  defp sign(typ, claims) do
    {_, token} =
      JOSE.JWT.sign(jwk(), %{"alg" => "HS256", "typ" => typ}, claims) |> JOSE.JWS.compact()

    token
  end

  @doc "Access + refresh JWTs for a DID."
  @spec create_tokens(String.t(), keyword) :: %{
          access_jwt: String.t(),
          refresh_jwt: String.t(),
          refresh_id: String.t()
        }
  def create_tokens(did, opts \\ []) do
    scope = Keyword.get(opts, :scope, :access)
    jti = Keyword.get(opts, :jti) || refresh_id()
    now = System.os_time(:second)
    aud = Config.service_did()

    access =
      sign("at+jwt", %{
        "scope" => scope_string(scope),
        "aud" => aud,
        "sub" => did,
        "iat" => now,
        "exp" => now + @access_ttl
      })

    refresh =
      sign("refresh+jwt", %{
        "scope" => scope_string(:refresh),
        "aud" => aud,
        "sub" => did,
        "jti" => jti,
        "iat" => now,
        "exp" => now + @refresh_ttl
      })

    %{access_jwt: access, refresh_jwt: refresh, refresh_id: jti}
  end

  @doc "A new session: tokens plus the stored refresh row (not stored for taken-down accounts, as upstream)."
  @spec create_session(String.t(), map | nil, boolean) :: %{
          access_jwt: String.t(),
          refresh_jwt: String.t()
        }
  def create_session(did, app_password \\ nil, soft_deleted? \\ false) do
    scope = scope_for(app_password, soft_deleted?)
    tokens = create_tokens(did, scope: scope)

    unless soft_deleted? do
      store_refresh(tokens.refresh_id, did, app_password && app_password.name)
    end

    Map.take(tokens, [:access_jwt, :refresh_jwt])
  end

  defp store_refresh(id, did, app_password_name) do
    Repo.insert_all(
      RefreshToken,
      [
        %{
          id: id,
          did: did,
          expires_at: DateTime.add(DateTime.utc_now(), @refresh_ttl),
          app_password_name: app_password_name
        }
      ],
      on_conflict: :nothing
    )
  end

  @doc "Verifies a bearer JWT of the given typ; returns the claims."
  @spec verify(String.t(), String.t()) ::
          {:ok, map} | {:error, :invalid_token | :expired_token | :bad_token_type | :bad_audience}
  def verify(token, expected_typ) do
    case JOSE.JWT.verify_strict(jwk(), ["HS256"], token) do
      {true, %JOSE.JWT{fields: claims}, %JOSE.JWS{fields: %{"typ" => typ}}} ->
        now = System.os_time(:second)

        cond do
          typ != expected_typ -> {:error, :bad_token_type}
          claims["aud"] != Config.service_did() -> {:error, :bad_audience}
          not is_integer(claims["exp"]) or claims["exp"] <= now -> {:error, :expired_token}
          true -> {:ok, claims}
        end

      _ ->
        {:error, :invalid_token}
    end
  rescue
    _ -> {:error, :invalid_token}
  end

  @doc "Upstream `rotateRefreshToken`: nil when revoked/expired; the same successor during the grace period."
  @spec rotate(String.t()) :: {:ok, %{access_jwt: String.t(), refresh_jwt: String.t()}} | nil
  def rotate(id) do
    case Repo.one(from(t in RefreshToken, where: t.id == ^id)) do
      nil ->
        nil

      token ->
        now = DateTime.utc_now()

        Repo.delete_all(
          from(t in RefreshToken, where: t.did == ^token.did and t.expires_at <= ^now)
        )

        grace_expiry = DateTime.add(now, @grace)

        expires_at =
          if DateTime.compare(grace_expiry, token.expires_at) == :lt,
            do: grace_expiry,
            else: token.expires_at

        if DateTime.compare(expires_at, now) != :gt do
          nil
        else
          next_id = token.next_id || refresh_id()
          app_password = app_password_descript(token)
          tokens = create_tokens(token.did, scope: scope_for(app_password, false), jti: next_id)

          Repo.transaction(fn ->
            # add the grace period to the old token; a concurrent rotation that got there first wins
            {updated, _} =
              Repo.update_all(
                from(t in RefreshToken,
                  where: t.id == ^id and (is_nil(t.next_id) or t.next_id == ^next_id)
                ),
                set: [expires_at: expires_at, next_id: next_id]
              )

            if updated == 0, do: Repo.rollback(:concurrent_refresh)
            store_refresh(next_id, token.did, token.app_password_name)
          end)
          |> case do
            {:ok, _} -> {:ok, Map.take(tokens, [:access_jwt, :refresh_jwt])}
            {:error, :concurrent_refresh} -> rotate(id)
          end
        end
    end
  end

  defp app_password_descript(%RefreshToken{app_password_name: nil}), do: nil

  defp app_password_descript(%RefreshToken{did: did, app_password_name: name}) do
    case Repo.one(from(p in AppPassword, where: p.did == ^did and p.name == ^name)) do
      nil -> %{name: name, privileged: false}
      p -> %{name: name, privileged: p.privileged}
    end
  end

  @spec revoke(String.t()) :: :ok
  def revoke(id) do
    Repo.delete_all(from(t in RefreshToken, where: t.id == ^id))
    :ok
  end

  @spec revoke_all(String.t()) :: :ok
  def revoke_all(did) do
    Repo.delete_all(from(t in RefreshToken, where: t.did == ^did))
    :ok
  end

  @spec revoke_app_password_tokens(String.t(), String.t()) :: :ok
  def revoke_app_password_tokens(did, name) do
    Repo.delete_all(
      from(t in RefreshToken, where: t.did == ^did and t.app_password_name == ^name)
    )

    :ok
  end

  @doc "Upstream `getRefreshTokenId`: 32 random bytes, base32-ish string."
  def refresh_id, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
end
