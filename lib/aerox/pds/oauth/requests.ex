defmodule Aerox.PDS.OAuth.Requests do
  @moduledoc """
  Authorization requests (upstream `request-manager.ts`): created by PAR
  (five-minute expiry), validated rule for rule, fetched by `request_uri`
  on `/oauth/authorize` (bound to the device, refreshed to a five-minute
  inactivity timeout), authorized once into a single-use `code`, consumed
  by the token endpoint.
  """
  import Ecto.Query
  alias Aerox.ATProto.Syntax
  alias Aerox.PDS.OAuth.Clients
  alias Aerox.PDS.OAuth.Clients.Client
  alias Aerox.PDS.Repo
  alias Aerox.PDS.Schema.AuthorizationRequest

  @prefix "urn:ietf:params:oauth:request_uri:"
  @par_expires_s 5 * 60
  @inactivity_s 5 * 60

  def request_uri(id), do: @prefix <> URI.encode_www_form(id)

  def parse_request_uri(@prefix <> rest) do
    id = URI.decode_www_form(rest)

    if String.starts_with?(id, "req-"),
      do: {:ok, id},
      else: {:error, {:invalid_request, "Invalid \"request_uri\" query parameter"}}
  end

  def parse_request_uri(_),
    do: {:error, {:invalid_request, "Invalid \"request_uri\" query parameter"}}

  defp gen(prefix, bytes),
    do: prefix <> Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)

  @doc "Validate parameters and store a request; returns `{request_uri, expires_at, parameters}`."
  def create(%Client{} = client, client_auth, params, device_id \\ nil) do
    with {:ok, params} <- validate(client, client_auth, params) do
      id = gen("req-", 16)
      expires = DateTime.add(DateTime.utc_now(), @par_expires_s, :second)

      Repo.insert!(%AuthorizationRequest{
        id: id,
        client_id: client.id,
        client_auth: client_auth,
        parameters: params,
        expires_at: expires,
        device_id: device_id
      })

      {:ok, %{request_uri: request_uri(id), expires_at: expires, parameters: params}}
    end
  end

  @doc "Upstream RequestManager.validate + Client.validateRequest."
  def validate(%Client{} = client, client_auth, p) do
    err = fn msg -> {:error, {:invalid_request, msg}} end

    with :ok <- reject_unsupported(p),
         :ok <-
           if(p["response_type"] == "code",
             do: :ok,
             else:
               {:error,
                {:unsupported_response_type,
                 "Unsupported response_type \"#{p["response_type"]}\""}}
           ),
         :ok <-
           if(p["client_id"] == client.id,
             do: :ok,
             else:
               err.(
                 "The \"client_id\" parameter field does not match the value used to authenticate the client"
               )
           ),
         :ok <- check_declared_scopes(client, p["scope"]),
         :ok <-
           if("code" in client.metadata["response_types"],
             do: :ok,
             else: err.("Invalid response_type \"code\" requested by the client")
           ),
         :ok <-
           if("authorization_code" in client.metadata["grant_types"],
             do: :ok,
             else: err.("This client is not allowed to use the \"authorization_code\" grant type")
           ),
         {:ok, p} <- resolve_redirect_uri(client, p),
         :ok <-
           if(p["authorization_details"],
             do: err.("authorization_details are not supported"),
             else: :ok
           ),
         {:ok, p} <- check_pkce(p),
         :ok <- check_scope_tokens(p["scope"]),
         {:ok, p} <- apply_prompt_rules(client, client_auth, p),
         {:ok, p} <- check_login_hint(p) do
      {:ok, p}
    end
  end

  defp reject_unsupported(p) do
    case Enum.find(["claims", "id_token_hint", "nonce"], &Map.has_key?(p, &1)) do
      nil -> :ok
      k -> {:error, {:invalid_request, "Unsupported \"#{k}\" parameter"}}
    end
  end

  defp check_declared_scopes(_client, nil), do: :ok

  defp check_declared_scopes(client, scope) do
    declared = client.metadata["scope"] && String.split(client.metadata["scope"], " ")

    cond do
      is_nil(declared) ->
        {:error, {:invalid_scope, "Client has no declared scopes in its metadata"}}

      true ->
        case Enum.find(String.split(scope, " ", trim: true), &(&1 not in declared)) do
          nil -> :ok
          s -> {:error, {:invalid_scope, "Scope \"#{s}\" is not declared in the client metadata"}}
        end
    end
  end

  defp resolve_redirect_uri(client, p) do
    case p["redirect_uri"] do
      nil ->
        case Clients.default_redirect_uri(client) do
          nil -> {:error, {:invalid_request, "redirect_uri is required"}}
          uri -> {:ok, Map.put(p, "redirect_uri", uri)}
        end

      uri ->
        if Clients.redirect_uri_allowed?(client, uri),
          do: {:ok, p},
          else: {:error, {:invalid_request, "Invalid redirect_uri #{uri}"}}
    end
  end

  defp check_pkce(p) do
    cond do
      is_nil(p["code_challenge"]) and p["code_challenge_method"] ->
        {:error,
         {:invalid_request, "code_challenge is required when code_challenge_method is provided"}}

      is_nil(p["code_challenge"]) ->
        {:error, {:invalid_request, "Use of PKCE is required"}}

      p["code_challenge_method"] in [nil, "plain"] ->
        {:error, {:invalid_request, "atproto requires use of \"S256\" code_challenge_method"}}

      p["code_challenge_method"] != "S256" ->
        {:error,
         {:invalid_request, "Unsupported code_challenge_method \"#{p["code_challenge_method"]}\""}}

      true ->
        {:ok, p}
    end
  end

  defp check_scope_tokens(scope) do
    scopes = String.split(scope || "", " ", trim: true)

    cond do
      "atproto" not in scopes ->
        {:error, {:invalid_scope, "The \"atproto\" scope is required"}}

      "openid" in scopes ->
        {:error, {:invalid_scope, "OpenID Connect is not compatible with atproto"}}

      true ->
        case Enum.find(scopes, &is_nil(Aerox.Auth.Scopes.parse(&1))) do
          nil -> :ok
          bad -> {:error, {:invalid_scope, "Invalid scope \"#{bad}\""}}
        end
    end
  end

  # public clients (not trusted) always get a consent prompt
  defp apply_prompt_rules(client, _client_auth, p) do
    if not client.trusted and client.metadata["token_endpoint_auth_method"] == "none" do
      cond do
        p["prompt"] == "none" ->
          {:error, {:consent_required, "Public clients are not allowed to use silent-sign-on"}}

        p["prompt"] == "create" ->
          {:ok, p}

        true ->
          {:ok, Map.put(p, "prompt", "consent")}
      end
    else
      {:ok, p}
    end
  end

  defp check_login_hint(%{"login_hint" => hint} = p) when is_binary(hint) do
    hint = String.downcase(hint)

    if Syntax.valid_did?(hint) or Syntax.valid_handle?(hint),
      do: {:ok, Map.put(p, "login_hint", hint)},
      else: {:error, {:invalid_request, "Invalid login_hint \"#{hint}\""}}
  end

  defp check_login_hint(p), do: {:ok, p}

  # ---------------------------------------------------------------- get

  @doc "Fetch a request for the authorize page, binding it to the device."
  def get(request_uri, device_id, client_id \\ nil) do
    with {:ok, id} <- parse_request_uri(request_uri),
         %AuthorizationRequest{} = r <-
           Repo.get(AuthorizationRequest, id) ||
             {:error, {:invalid_request, "Unknown request_uri"}} do
      now = DateTime.utc_now()

      cond do
        r.did || r.code ->
          delete(id)
          {:error, {:access_denied, "This request was already authorized", r.parameters}}

        DateTime.compare(r.expires_at, now) == :lt ->
          delete(id)
          {:error, {:access_denied, "This request has expired", r.parameters}}

        client_id && r.client_id != client_id ->
          delete(id)

          {:error,
           {:access_denied, "This request was initiated for another client", r.parameters}}

        r.device_id && device_id && r.device_id != device_id ->
          delete(id)

          {:error,
           {:access_denied, "This request was initiated from another device", r.parameters}}

        true ->
          expires = DateTime.add(now, @inactivity_s, :second)

          Repo.update_all(from(a in AuthorizationRequest, where: a.id == ^id),
            set: [expires_at: expires, device_id: r.device_id || device_id]
          )

          {:ok, %{r | expires_at: expires, device_id: r.device_id || device_id}}
      end
    end
  end

  def peek_client_id(request_uri) do
    with {:ok, id} <- parse_request_uri(request_uri),
         %{client_id: c} <- Repo.get(AuthorizationRequest, id),
         do: c,
         else: (_ -> nil)
  end

  @doc "Upstream setAuthorized: issues the single-use code."
  def set_authorized(request_uri, did, device_id, scope_override \\ nil) do
    with {:ok, id} <- parse_request_uri(request_uri),
         %AuthorizationRequest{} = r <-
           Repo.get(AuthorizationRequest, id) ||
             {:error, {:invalid_request, "Unknown request_uri"}} do
      now = DateTime.utc_now()

      cond do
        DateTime.compare(r.expires_at, now) == :lt ->
          denied(id, "This request has expired", r)

        is_nil(r.device_id) ->
          denied(id, "This request was not initiated", r)

        r.device_id != device_id ->
          denied(id, "This request was initiated from another device", r)

        r.did || r.code ->
          denied(id, "This request was already authorized", r)

        true ->
          params =
            case scope_override do
              nil ->
                r.parameters

              allowed ->
                allowed = String.split(allowed, " ", trim: true)

                kept =
                  r.parameters["scope"]
                  |> String.split(" ", trim: true)
                  |> Enum.filter(&(&1 in allowed))

                Map.put(r.parameters, "scope", Enum.join(kept, " "))
            end

          if "atproto" not in String.split(params["scope"] || "", " ") do
            denied(id, "The \"atproto\" scope is required", r)
          else
            code = gen("cod-", 32)

            Repo.update_all(from(a in AuthorizationRequest, where: a.id == ^id),
              set: [
                did: did,
                code: code,
                expires_at: DateTime.add(now, @inactivity_s, :second),
                parameters: params
              ]
            )

            {:ok, code, params}
          end
      end
    end
  end

  defp denied(id, msg, r) do
    delete(id)
    {:error, {:access_denied, msg, r.parameters}}
  end

  @doc "Consume a code (deleting the request); returns the authorized request data."
  def consume_code(code) do
    Repo.transaction(fn ->
      case Repo.one(from(a in AuthorizationRequest, where: a.code == ^code, lock: "FOR UPDATE")) do
        nil ->
          Repo.rollback({:invalid_grant, "Invalid code"})

        r ->
          Repo.delete!(r)

          if is_nil(r.did) or DateTime.compare(r.expires_at, DateTime.utc_now()) == :lt,
            do: Repo.rollback({:invalid_grant, "Invalid code"}),
            else: r
      end
    end)
  end

  def delete(id) do
    Repo.delete_all(from(a in AuthorizationRequest, where: a.id == ^id))
    :ok
  end

  def delete_by_uri(request_uri) do
    with {:ok, id} <- parse_request_uri(request_uri), do: delete(id)
  end
end
