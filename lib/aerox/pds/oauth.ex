defmodule Aerox.PDS.OAuth do
  @moduledoc """
  The atproto OAuth authorization server (DESIGN §11.2), orchestrating
  `Clients`, `Requests`, `Tokens`, `Keys` and the shared `Aerox.Auth.DPoP`
  verifier: server metadata, PAR, the authorize page's data, sign-in,
  consent, the token endpoint (code and refresh grants), revocation, and
  resource-side access-token verification for the PDS's own XRPC routes.
  Errors are `{:error, {error, description}}` in OAuth's error vocabulary.
  """
  import Ecto.Query
  alias Aerox.Auth.DPoP
  alias Aerox.PDS.{Accounts, Config, Repo}
  alias Aerox.PDS.OAuth.{Clients, Keys, Requests, Tokens}
  alias Aerox.PDS.Schema.{AccountDevice, AuthorizedClient, Device}

  def issuer, do: Config.public_url()

  # ------------------------------------------------------------ metadata

  @doc "`/.well-known/oauth-authorization-server` (RFC 8414), as upstream buildMetadata."
  def server_metadata do
    iss = issuer()

    %{
      "issuer" => iss,
      "scopes_supported" => [
        "atproto",
        "transition:email",
        "transition:generic",
        "transition:chat.bsky"
      ],
      "subject_types_supported" => ["public"],
      "response_types_supported" => ["code"],
      "response_modes_supported" => ["query", "fragment", "form_post"],
      "grant_types_supported" => ["authorization_code", "refresh_token"],
      "code_challenge_methods_supported" => ["S256"],
      "ui_locales_supported" => ["en-US"],
      "display_values_supported" => ["page", "popup", "touch"],
      "prompt_values_supported" => ["none", "login", "consent", "select_account", "create"],
      "authorization_response_iss_parameter_supported" => true,
      "request_object_signing_alg_values_supported" => ["none"],
      "request_object_encryption_alg_values_supported" => [],
      "request_object_encryption_enc_values_supported" => [],
      "request_parameter_supported" => false,
      "request_uri_parameter_supported" => true,
      "require_request_uri_registration" => true,
      "jwks_uri" => iss <> "/oauth/jwks",
      "authorization_endpoint" => iss <> "/oauth/authorize",
      "token_endpoint" => iss <> "/oauth/token",
      "token_endpoint_auth_methods_supported" => ["none", "private_key_jwt"],
      "token_endpoint_auth_signing_alg_values_supported" => [
        "ES256",
        "ES256K",
        "ES384",
        "ES512",
        "RS256",
        "RS384",
        "RS512",
        "PS256",
        "PS384",
        "PS512"
      ],
      "revocation_endpoint" => iss <> "/oauth/revoke",
      "pushed_authorization_request_endpoint" => iss <> "/oauth/par",
      "require_pushed_authorization_requests" => true,
      "dpop_signing_alg_values_supported" => [
        "ES256",
        "ES256K",
        "ES384",
        "ES512",
        "RS256",
        "RS384",
        "RS512",
        "PS256",
        "PS384",
        "PS512"
      ],
      "protected_resources" => [iss],
      "client_id_metadata_document_supported" => true
    }
  end

  @doc "`/.well-known/oauth-protected-resource` (RFC 9728), as upstream auth-routes.ts."
  def protected_resource_metadata do
    %{
      "resource" => Config.public_url(),
      "authorization_servers" => [issuer()],
      "bearer_methods_supported" => ["header"],
      "scopes_supported" => [],
      "resource_documentation" => "https://atproto.com"
    }
  end

  def jwks, do: Keys.public_jwks()

  # ---------------------------------------------------------- clients

  @doc "Upstream authenticateClient."
  def authenticate_client(creds, dpop, opts \\ []) do
    client_id = creds["client_id"] || ""

    with {:ok, client} <- Clients.get(client_id),
         :ok <- check_dpop_expectation(client, dpop, opts),
         {:ok, auth} <- Clients.authenticate(client, creds, issuer()),
         :ok <-
           if(Clients.dpop_key_conflict?(auth, dpop),
             do:
               {:error,
                {:invalid_request,
                 "The DPoP proof must be signed with a different key than the client assertion"}},
             else: :ok
           ),
         :ok <- unique_assertion(auth, client.id) do
      {:ok, client, auth}
    end
  end

  defp check_dpop_expectation(client, dpop, opts) do
    bound = client.metadata["dpop_bound_access_tokens"]

    cond do
      bound and is_nil(dpop) and not Keyword.get(opts, :allow_missing_dpop, false) ->
        {:error, {:invalid_dpop_proof, "DPoP proof required"}}

      dpop && not bound ->
        {:error, {:invalid_dpop_proof, "DPoP proof not allowed for this client"}}

      true ->
        :ok
    end
  end

  # private_key_jwt jti replay (ETS)
  defp unique_assertion(%{"method" => "private_key_jwt", "jti" => jti}, client_id) do
    table = __MODULE__.AssertionReplay
    if :ets.whereis(table) == :undefined, do: :ets.new(table, [:named_table, :public, :set])
    now = System.os_time(:millisecond)
    :ets.select_delete(table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])

    if :ets.insert_new(table, {{client_id, jti}, now + 66_000}),
      do: :ok,
      else: {:error, {:invalid_grant, "private_key_jwt jti reused"}}
  end

  defp unique_assertion(_, _), do: :ok

  # -------------------------------------------------------------- PAR

  @doc "`POST /oauth/par` (upstream pushedAuthorizationRequest)."
  def par(body, dpop) do
    with {:ok, client, auth} <- authenticate_client(body, dpop, allow_missing_dpop: true),
         {:ok, params} <- bind_dpop_jkt(client, body, dpop),
         {:ok, %{request_uri: uri, expires_at: expires}} <- Requests.create(client, auth, params) do
      {:ok, %{"request_uri" => uri, "expires_in" => DateTime.diff(expires, DateTime.utc_now())}}
    else
      {:error, {err, msg}}
      when err in [:unsupported_response_type, :invalid_scope, :consent_required] ->
        {:error, {:invalid_request, msg}}

      e ->
        e
    end
  end

  @par_keys ~w(client_id state redirect_uri scope response_type code_challenge code_challenge_method dpop_jkt response_mode nonce max_age claims login_hint ui_locales id_token_hint display prompt authorization_details)

  defp bind_dpop_jkt(client, body, dpop) do
    params = Map.take(body, @par_keys)
    bound = client.metadata["dpop_bound_access_tokens"]

    cond do
      is_nil(params["dpop_jkt"]) and bound and dpop ->
        {:ok, Map.put(params, "dpop_jkt", dpop.jkt)}

      is_nil(params["dpop_jkt"]) ->
        {:ok, params}

      not bound ->
        {:error, {:invalid_request, "DPoP bound access tokens are not enabled for this client"}}

      dpop && dpop.jkt != params["dpop_jkt"] ->
        {:error, {:invalid_dpop_proof, "DPoP key binding mismatch"}}

      true ->
        {:ok, params}
    end
  end

  # -------------------------------------------------------- authorize

  @doc """
  `GET /oauth/authorize?client_id&request_uri`: the request bound to the
  device, plus what the page needs (client, parameters, the device's
  accounts). `prompt=none` without a usable session is an error redirect.
  """
  def authorize(query, device_id) do
    with {:ok, client} <- Clients.get(query["client_id"] || ""),
         {:ok, request} <- get_request(query, client, device_id) do
      sessions = device_accounts(device_id)
      params = request.parameters

      hinted =
        Enum.find(sessions, fn %{did: did, handle: handle} ->
          params["login_hint"] in [did, handle]
        end)

      cond do
        params["prompt"] == "none" and
            (hinted == nil or consent_required?(hinted.did, client, params)) ->
          {:redirect, params, error_redirect(params, "login_required", "Login required")}

        params["prompt"] == "none" ->
          case Requests.set_authorized(request_uri(request), hinted.did, device_id) do
            {:ok, code, params} ->
              {:redirect, params, %{"code" => code}}

            {:error, {_, msg, params}} ->
              {:redirect, params, error_redirect(params, "access_denied", msg)}
          end

        true ->
          {:page,
           %{
             client: client,
             parameters: params,
             request_uri: request_uri(request),
             sessions: sessions,
             selected_did: hinted && hinted.did,
             consent_required: true
           }}
      end
    end
  end

  defp get_request(%{"request_uri" => uri}, client, device_id),
    do: Requests.get(uri, device_id, client.id)

  defp get_request(_, _, _),
    do:
      {:error,
       {:invalid_request, "Missing \"request_uri\" (pushed authorization requests are required)"}}

  defp request_uri(%{id: id}), do: Requests.request_uri(id)

  defp consent_required?(did, client, params) do
    scopes = String.split(params["scope"] || "", " ", trim: true)

    case Repo.get_by(AuthorizedClient, did: did, client_id: client.id) do
      nil ->
        true

      %{data: %{"authorizedScopes" => granted}} ->
        params["prompt"] == "consent" or Enum.any?(scopes, &(&1 not in granted))

      _ ->
        true
    end
  end

  @doc "Sign in on the authorize page: password login, remembered on the device."
  def sign_in(request_uri, identifier, password, device_id, device_meta) do
    _ = Requests.peek_client_id(request_uri)

    case Accounts.login(identifier, password) do
      {:ok, account, _app_password} ->
        if Accounts.soft_deleted?(account),
          do: {:error, {:invalid_request, "Account has been taken down"}},
          else: remember(device_id, device_meta, account.did)

      {:error, _} ->
        {:error, {:invalid_request, "Invalid identifier or password"}}
    end
  end

  defp remember(device_id, meta, did) do
    now = DateTime.utc_now()
    ensure_device(device_id, meta)

    Repo.insert!(%AccountDevice{did: did, device_id: device_id, created_at: now, updated_at: now},
      on_conflict: {:replace, [:updated_at]},
      conflict_target: [:did, :device_id]
    )

    {:ok, did}
  end

  @doc "Upsert the device row for the cookie-identified browser."
  def ensure_device(device_id, meta \\ %{}) do
    now = DateTime.utc_now()

    Repo.insert!(
      %Device{
        id: device_id,
        session_id: meta[:session_id] || device_id,
        user_agent: meta[:user_agent],
        ip_address: meta[:ip] || "0.0.0.0",
        last_seen_at: now
      },
      on_conflict: {:replace, [:last_seen_at, :user_agent, :ip_address]},
      conflict_target: :id
    )

    :ok
  end

  def device_accounts(nil), do: []

  def device_accounts(device_id) do
    dids =
      Repo.all(
        from(a in AccountDevice,
          where: a.device_id == ^device_id,
          order_by: [desc: a.updated_at],
          select: a.did
        )
      )

    for did <- dids,
        acc = Accounts.get_account(did),
        do: %{did: did, handle: acc.handle, email: acc.email}
  end

  @doc "Consent: the signed-in account (which must be on this device) authorizes the request → code."
  def consent(request_uri, did, device_id, scope_override \\ nil) do
    with true <-
           did in Enum.map(device_accounts(device_id), & &1.did) ||
             {:error, {:invalid_request, "Account not signed in on this device"}},
         client_id = Requests.peek_client_id(request_uri),
         {:ok, client} <- Clients.get(client_id || ""),
         {:ok, code, params} <-
           Requests.set_authorized(request_uri, did, device_id, scope_override) do
      record_authorized_client(did, client.id, params["scope"])
      {:ok, params, %{"code" => code}}
    else
      {:error, {:access_denied, msg, params}} ->
        {:redirect_error, params, error_redirect(params, "access_denied", msg)}

      {:error, _} = e ->
        e
    end
  end

  defp record_authorized_client(did, client_id, scope) do
    now = DateTime.utc_now()
    existing = Repo.get_by(AuthorizedClient, did: did, client_id: client_id)
    granted = (existing && existing.data["authorizedScopes"]) || []
    scopes = Enum.uniq(granted ++ String.split(scope || "", " ", trim: true))

    Repo.insert!(
      %AuthorizedClient{
        did: did,
        client_id: client_id,
        created_at: now,
        updated_at: now,
        data: %{"authorizedScopes" => scopes}
      },
      on_conflict: {:replace, [:updated_at, :data]},
      conflict_target: [:did, :client_id]
    )
  end

  @doc "Reject on the consent page → error redirect."
  def reject(request_uri) do
    case Requests.get(request_uri, nil) do
      {:ok, r} ->
        Requests.delete_by_uri(request_uri)

        {:ok, r.parameters,
         error_redirect(r.parameters, "access_denied", "The user rejected the request")}

      {:error, {:access_denied, msg, params}} ->
        {:ok, params, error_redirect(params, "access_denied", msg)}

      e ->
        e
    end
  end

  defp error_redirect(_params, error, description),
    do: %{"error" => error, "error_description" => description}

  @doc "Build the client redirect: `{mode, redirect_uri, params}` with `iss` and `state` (RFC 9207)."
  def redirect(params, extra) do
    query = Map.merge(%{"iss" => issuer()}, extra)
    query = if params["state"], do: Map.put(query, "state", params["state"]), else: query
    mode = params["response_mode"] || "query"
    {mode, params["redirect_uri"], query}
  end

  # ------------------------------------------------------------- token

  @doc "`POST /oauth/token` (upstream token): code and refresh grants."
  def token(body, dpop) do
    with {:ok, client, auth} <- authenticate_client(body, dpop) do
      case body["grant_type"] do
        "authorization_code" -> code_grant(client, auth, body, dpop)
        "refresh_token" -> refresh_grant(client, auth, body, dpop)
        gt -> {:error, {:invalid_grant, "Grant type \"#{gt}\" is not supported by the server"}}
      end
    end
  end

  defp code_grant(client, auth, body, dpop) do
    aud = Config.service_did()

    with :ok <-
           if("authorization_code" in client.metadata["grant_types"],
             do: :ok,
             else:
               {:error,
                {:invalid_grant,
                 "\"authorization_code\" grant type is not allowed for this client"}}
           ),
         code when is_binary(code) <- body["code"] || {:error, {:invalid_grant, "Invalid code"}},
         {:ok, request} <- consume(code),
         :ok <-
           Tokens.compare_client_auth(
             %{
               client_id: request.client_id,
               client_auth: request.client_auth,
               parameters: request.parameters
             },
             client,
             auth,
             dpop
           ),
         params = maybe_bind(request.parameters, client, dpop),
         :ok <- validate_code_grant(params, body),
         :ok <-
           if(client.metadata["dpop_bound_access_tokens"] and is_nil(params["dpop_jkt"]),
             do: {:error, {:invalid_grant, "DPoP JKT is required for DPoP bound access tokens"}},
             else: :ok
           ),
         %{} = _account <-
           Accounts.get_account(request.did) || {:error, {:invalid_grant, "Account not found"}} do
      {:ok,
       Tokens.create(client, auth, request.did, request.device_id, params, code, issuer(), aud)}
    end
  end

  defp consume(code) do
    case Requests.consume_code(code) do
      {:ok, r} ->
        {:ok, r}

      {:error, reason} ->
        # a replayed code revokes the token it produced
        Tokens.delete_by_code(code)
        {:error, reason}
    end
  end

  defp maybe_bind(params, client, dpop) do
    if dpop && client.metadata["dpop_bound_access_tokens"] && is_nil(params["dpop_jkt"]),
      do: Map.put(params, "dpop_jkt", dpop.jkt),
      else: params
  end

  # upstream validateCodeGrant (PKCE S256 only, challenge replay window)
  defp validate_code_grant(params, body) do
    verifier = body["code_verifier"]

    cond do
      params["redirect_uri"] != body["redirect_uri"] ->
        {:error,
         {:invalid_grant,
          "The redirect_uri parameter must match the one used in the authorization request"}}

      is_nil(verifier) ->
        {:error, {:invalid_grant, "code_verifier is required"}}

      String.length(verifier) < 43 ->
        {:error, {:invalid_grant, "code_verifier too short"}}

      Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false) !=
          String.trim_trailing(params["code_challenge"], "=") ->
        {:error, {:invalid_grant, "Invalid code_verifier"}}

      not unique_challenge(params["code_challenge"]) ->
        {:error, {:invalid_grant, "Code challenge already used"}}

      true ->
        :ok
    end
  end

  defp unique_challenge(challenge) do
    table = __MODULE__.ChallengeReplay
    if :ets.whereis(table) == :undefined, do: :ets.new(table, [:named_table, :public, :set])
    now = System.os_time(:millisecond)

    if :rand.uniform(100) == 1,
      do: :ets.select_delete(table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])

    :ets.insert_new(table, {challenge, now + 26 * 3600 * 1000})
  end

  defp refresh_grant(client, auth, body, dpop) do
    with :ok <-
           if("refresh_token" in client.metadata["grant_types"],
             do: :ok,
             else:
               {:error,
                {:invalid_grant, "\"refresh_token\" grant type is not allowed for this client"}}
           ),
         token when is_binary(token) <-
           body["refresh_token"] || {:error, {:invalid_grant, "Invalid refresh token"}} do
      Tokens.refresh(token, client, auth, dpop, issuer(), Config.service_did())
    end
  end

  # ------------------------------------------------------------ revoke

  def revoke(body, dpop) do
    with {:ok, client, auth} <- authenticate_client(body, dpop, allow_missing_dpop: true) do
      case body["token"] && Tokens.find(body["token"]) do
        %{} = row ->
          case Tokens.compare_client_auth(row, client, auth, dpop) do
            :ok -> Tokens.delete(row.id)
            _ -> :ok
          end

        _ ->
          :ok
      end
    end
  end

  # ---------------------------------------------------- resource side

  @doc """
  Verifies an `authorization: DPoP <token>` (or Bearer) header on an XRPC
  request. `dpop` is the verified proof (with `ath` over the token).
  """
  def verify_request(scheme, token, dpop),
    do: Tokens.verify_access(token, scheme, dpop, Config.service_did())

  @doc "The DPoP nonce to advertise on every OAuth and XRPC response."
  def next_dpop_nonce, do: DPoP.next_nonce()
end
