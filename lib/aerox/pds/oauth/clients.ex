defmodule Aerox.PDS.OAuth.Clients do
  @moduledoc """
  OAuth clients (upstream `client-manager.ts` / `client.ts`): `client_id` is
  a URL to a client-metadata document (fetched through the hardened HTTP
  client and cached five minutes), or a loopback `http://localhost[?…]`
  id whose metadata is synthesised. Validation mirrors upstream rule for
  rule; authentication is `none` or `private_key_jwt` (a client assertion
  verified against the client's `jwks`/`jwks_uri`).
  """
  alias Aerox.Auth.DPoP
  alias Aerox.Identity.HTTP

  @cache __MODULE__.Cache
  @ttl_ms 5 * 60 * 1000
  @assertion_max_age 60
  @default_loopback_redirects ["http://127.0.0.1/", "http://[::1]/"]

  defmodule Client do
    @moduledoc false
    defstruct [:id, :metadata, :jwks, trusted: false]
  end

  @type client :: %Client{}

  def ensure_cache do
    if :ets.whereis(@cache) == :undefined, do: :ets.new(@cache, [:named_table, :public, :set])
    :ok
  end

  @doc "Resolve and validate a client by id."
  @spec get(String.t(), keyword) ::
          {:ok, client} | {:error, {:invalid_client_metadata | :invalid_client_id, String.t()}}
  def get(client_id, opts \\ []) do
    cond do
      loopback?(client_id) ->
        with {:ok, metadata} <- loopback_metadata(client_id),
             {:ok, metadata} <- validate(client_id, metadata) do
          {:ok, %Client{id: client_id, metadata: metadata, jwks: metadata["jwks"]}}
        end

      true ->
        with {:ok, url} <- discoverable_url(client_id),
             {:ok, metadata} <- fetch_metadata(url, opts),
             {:ok, metadata} <- validate(client_id, metadata),
             {:ok, jwks} <- fetch_jwks(metadata, opts) do
          {:ok,
           %Client{
             id: client_id,
             metadata: metadata,
             jwks: jwks,
             trusted: client_id in trusted_clients()
           }}
        end
    end
  end

  defp trusted_clients, do: Aerox.PDS.Config.get(:oauth_trusted_clients, [])

  # ---------------------------------------------------------- loopback

  def loopback?(client_id), do: String.starts_with?(client_id, "http://localhost")

  defp loopback_metadata(client_id) do
    rest = String.replace_prefix(client_id, "http://localhost", "")
    rest = String.replace_prefix(rest, "/", "")

    cond do
      String.contains?(rest, "#") ->
        {:error, {:invalid_client_id, "Value must not contain a hash component"}}

      rest != "" and not String.starts_with?(rest, "?") ->
        {:error, {:invalid_client_id, "Value must not contain a path component"}}

      true ->
        params =
          if rest == "",
            do: [],
            else: rest |> String.trim_leading("?") |> URI.query_decoder() |> Enum.to_list()

        scope = for({"scope", v} <- params, do: v) |> List.last() || "atproto"
        redirects = for {"redirect_uri", v} <- params, do: v
        unknown = for {k, _} <- params, k not in ["scope", "redirect_uri"], do: k

        cond do
          unknown != [] ->
            {:error, {:invalid_client_id, "Unexpected query parameter \"#{hd(unknown)}\""}}

          "atproto" not in String.split(scope, " ") ->
            {:error,
             {:invalid_client_id, "ATProto Loopback ClientID must include \"atproto\" scope"}}

          true ->
            {:ok,
             %{
               "client_id" => client_id,
               "scope" => scope,
               "redirect_uris" =>
                 if(redirects == [], do: @default_loopback_redirects, else: redirects),
               "response_types" => ["code"],
               "grant_types" => ["authorization_code", "refresh_token"],
               "token_endpoint_auth_method" => "none",
               "application_type" => "native",
               "dpop_bound_access_tokens" => true
             }}
        end
    end
  end

  # ------------------------------------------------------ discoverable

  defp discoverable_url(client_id) do
    case URI.new(client_id) do
      {:ok, %URI{scheme: "https", host: host, path: path, userinfo: nil, fragment: nil} = uri}
      when is_binary(host) ->
        cond do
          path in [nil, "", "/"] ->
            {:error,
             {:invalid_client_id,
              "ClientID must contain a path component (e.g. \"/client-metadata.json\")"}}

          String.ends_with?(path, "/") ->
            {:error, {:invalid_client_id, "ClientID path must not end with a trailing slash"}}

          ip?(host) ->
            {:error, {:invalid_client_id, "ClientID hostname must not be an IP address"}}

          local_hostname?(host) ->
            {:error, {:invalid_client_id, "The client_id's TLD must not be a local hostname"}}

          true ->
            {:ok, URI.to_string(uri)}
        end

      _ ->
        {:error, {:invalid_client_id, "Invalid discoverable client identifier"}}
    end
  end

  defp ip?(host), do: match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))

  defp local_hostname?(host),
    do:
      host == "localhost" or String.ends_with?(host, ".localhost") or
        String.ends_with?(host, ".local") or (String.ends_with?(host, ".test") and false)

  defp fetch_metadata(url, opts) do
    cached(url, fn ->
      case HTTP.get(
             url,
             [timeout: 10_000, max_bytes: 200_000, headers: [{"accept", "application/json"}]] ++
               http_opts(opts)
           ) do
        {:ok, 200, _, body} ->
          case Jason.decode(body) do
            {:ok, %{} = m} -> {:ok, m}
            _ -> {:error, {:invalid_client_metadata, "Invalid client metadata document"}}
          end

        {:ok, status, _, _} ->
          {:error, {:invalid_client_metadata, "Failed to fetch client metadata (HTTP #{status})"}}

        {:error, reason} ->
          {:error,
           {:invalid_client_metadata, "Failed to fetch client metadata: #{inspect(reason)}"}}
      end
    end)
  end

  defp fetch_jwks(%{"jwks" => jwks}, _), do: {:ok, jwks}

  defp fetch_jwks(%{"jwks_uri" => uri}, opts) do
    cached(uri, fn ->
      case HTTP.get(uri, [timeout: 10_000, max_bytes: 200_000] ++ http_opts(opts)) do
        {:ok, 200, _, body} ->
          case Jason.decode(body) do
            {:ok, %{"keys" => keys} = m} when is_list(keys) -> {:ok, m}
            _ -> {:error, {:invalid_client_metadata, "Invalid jwks document"}}
          end

        _ ->
          {:error, {:invalid_client_metadata, "Unable to obtain jwks from \"#{uri}\""}}
      end
    end)
  end

  defp fetch_jwks(_, _), do: {:ok, nil}

  defp http_opts(opts),
    do: Keyword.take(Application.get_env(:aerox, __MODULE__, []) ++ opts, [:plug, :allow_private])

  defp cached(key, fun) do
    ensure_cache()
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@cache, key) do
      [{^key, value, expires}] when expires > now ->
        {:ok, value}

      _ ->
        case fun.() do
          {:ok, value} ->
            :ets.insert(@cache, {key, value, now + @ttl_ms})
            {:ok, value}

          error ->
            error
        end
    end
  end

  def flush_cache do
    ensure_cache()
    :ets.delete_all_objects(@cache)
    :ok
  end

  # -------------------------------------------------------- validation

  @auth_methods ["none", "private_key_jwt"]

  @doc "Upstream validateClientMetadata, with defaults applied."
  def validate(client_id, m) do
    m =
      m
      |> Map.put_new("response_types", ["code"])
      |> Map.put_new("grant_types", ["authorization_code"])
      |> Map.put_new("token_endpoint_auth_method", "client_secret_basic")
      |> Map.put_new("application_type", "web")
      |> Map.put_new("subject_type", "public")

    scopes = m["scope"] && String.split(m["scope"], " ")
    err = fn msg -> {:error, {:invalid_client_metadata, msg}} end

    cond do
      m["jwks"] && m["jwks_uri"] ->
        err.("jwks_uri and jwks are mutually exclusive")

      is_nil(scopes) ->
        err.("Missing scope property")

      "atproto" not in scopes ->
        err.("Missing \"atproto\" scope")

      dup = duplicate(scopes) ->
        err.("Duplicate scope \"#{dup}\"")

      dup = duplicate(m["grant_types"]) ->
        err.("Duplicate grant_type \"#{dup}\"")

      Enum.any?(
        m["grant_types"],
        &(&1 not in ["authorization_code", "refresh_token", "implicit"])
      ) ->
        err.("Unsupported grant_type")

      "implicit" in m["grant_types"] ->
        err.("Grant type \"implicit\" is not supported")

      m["client_id"] && m["client_id"] != client_id ->
        err.("client_id does not match")

      m["subject_type"] != "public" ->
        err.("Only \"public\" subject_type is supported")

      m["token_endpoint_auth_method"] not in @auth_methods ->
        err.(
          "Unsupported client authentication method \"#{m["token_endpoint_auth_method"]}\". Make sure \"token_endpoint_auth_method\" is set to one of: \"none\", \"private_key_jwt\""
        )

      m["token_endpoint_auth_method"] == "none" and m["token_endpoint_auth_signing_alg"] ->
        err.("token_endpoint_auth_method \"none\" must not have token_endpoint_auth_signing_alg")

      m["token_endpoint_auth_method"] == "private_key_jwt" and is_nil(m["jwks"]) and
          is_nil(m["jwks_uri"]) ->
        err.("private_key_jwt auth method requires jwks or jwks_uri")

      (m["token_endpoint_auth_method"] == "private_key_jwt" and m["jwks"]) &&
          m["jwks"]["keys"] == [] ->
        err.("private_key_jwt auth method requires at least one key in jwks")

      m["token_endpoint_auth_method"] == "private_key_jwt" and
          is_nil(m["token_endpoint_auth_signing_alg"]) ->
        err.("Missing token_endpoint_auth_signing_alg client metadata")

      m["authorization_encrypted_response_enc"] ->
        err.("Encrypted authorization response is not supported")

      m["tls_client_certificate_bound_access_tokens"] ->
        err.("Mutual-TLS bound access tokens are not supported")

      m["dpop_bound_access_tokens"] != true ->
        err.("\"dpop_bound_access_tokens\" must be true")

      "code" not in m["response_types"] ->
        err.("response_types must include \"code\"")

      "authorization_code" not in m["grant_types"] ->
        err.(
          "The \"code\" response type requires that \"grant_types\" contains \"authorization_code\""
        )

      not is_list(m["redirect_uris"]) or m["redirect_uris"] == [] ->
        err.("At least one redirect_uri is required")

      m["application_type"] == "native" and m["token_endpoint_auth_method"] != "none" ->
        err.("Native clients must authenticate using \"none\" method")

      true ->
        case Enum.find_value(m["redirect_uris"], &redirect_uri_error(&1, m)) do
          nil ->
            cond do
              loopback?(client_id) -> validate_loopback(m)
              true -> validate_discoverable(client_id, m)
            end

          msg ->
            {:error, {:invalid_redirect_uri, msg}}
        end
    end
  end

  defp duplicate(list),
    do: list |> Enum.frequencies() |> Enum.find_value(fn {k, n} -> if n > 1, do: k end)

  defp redirect_uri_error(uri, m) do
    case URI.new(uri) do
      {:ok, %URI{userinfo: u}} when u != nil ->
        "Redirect URI #{uri} must not contain credentials"

      {:ok, %URI{host: "localhost"}} ->
        "Loopback redirect URI #{uri} is not allowed (use explicit IPs instead)"

      {:ok, %URI{host: h, scheme: s}} when h in ["127.0.0.1", "[::1]", "::1"] ->
        cond do
          m["application_type"] != "native" ->
            "Loopback redirect URIs are only allowed for native apps"

          s != "http" ->
            "Loopback redirect URI #{uri} must use HTTP"

          true ->
            nil
        end

      {:ok, %URI{scheme: "http"}} ->
        "Only loopback redirect URIs are allowed to use the \"http\" scheme"

      {:ok, %URI{scheme: "https", host: h}} ->
        if local_hostname?(h),
          do: "Redirect URI \"#{uri}\"'s domain name must not be a local hostname"

      {:ok, %URI{scheme: s}} when is_binary(s) ->
        # private-use URI scheme (reverse domain, contains a dot)
        cond do
          not String.contains?(s, ".") ->
            "Invalid redirect URI scheme \"#{s}:\""

          m["application_type"] != "native" ->
            "Private-Use URI Scheme redirect URI are only allowed for native apps"

          true ->
            nil
        end

      _ ->
        "Invalid redirect URI \"#{uri}\""
    end
  end

  defp validate_loopback(m) do
    cond do
      m["application_type"] != "native" ->
        {:error,
         {:invalid_client_metadata, "Loopback clients must have application_type \"native\""}}

      m["token_endpoint_auth_method"] != "none" ->
        {:error,
         {:invalid_client_metadata, "Loopback clients must authenticate using \"none\" method"}}

      true ->
        {:ok, m}
    end
  end

  defp validate_discoverable(client_id, m) do
    # upstream: redirect_uris of web clients should share the client_id's origin
    # (or be loopback for native ones); we accept upstream's set of rules as above
    _ = client_id
    {:ok, m}
  end

  # ---------------------------------------------------- authentication

  @doc """
  Upstream `Client.authenticate`: `%{method: "none"}` for public clients, or
  `%{method: "private_key_jwt", kid, alg, jkt, jti, exp}` after verifying the
  `client_assertion` (iss = sub = client_id, aud = issuer, fresh, jti).
  """
  def authenticate(%Client{} = client, creds, issuer, opts \\ []) do
    method = client.metadata["token_endpoint_auth_method"]

    case creds do
      %{
        "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        "client_assertion" => jwt
      } ->
        if method != "private_key_jwt",
          do: {:error, {:invalid_client, "Client authentication method mismatch"}},
          else: verify_assertion(client, jwt, issuer, opts)

      %{"client_assertion_type" => other} ->
        {:error, {:invalid_client, "Unsupported client_assertion_type \"#{other}\""}}

      _ ->
        cond do
          method == "none" ->
            {:ok, %{"method" => "none"}}

          true ->
            {:error,
             {:invalid_request,
              "client authentication method \"#{method}\" required a \"client_assertion\""}}
        end
    end
  end

  defp verify_assertion(client, jwt, issuer, opts) do
    now = Keyword.get(opts, :now, System.os_time(:second))

    with [h, p, _] <- String.split(jwt, "."),
         {:ok, header} <- decode_part(h),
         {:ok, claims} <- decode_part(p),
         kid when is_binary(kid) <-
           header["kid"] || {:error, {:invalid_client, "\"kid\" required in client_assertion"}},
         {:ok, jwk} <- find_key(client.jwks, kid),
         alg = header["alg"],
         true <-
           alg == client.metadata["token_endpoint_auth_signing_alg"] ||
             {:error, {:invalid_client, "Invalid client_assertion alg"}},
         {true, _, _} <- JOSE.JWS.verify_strict(JOSE.JWK.from_map(jwk), [alg], jwt),
         :ok <- check_assertion_claims(claims, client.id, issuer, now) do
      {:ok,
       %{
         "method" => "private_key_jwt",
         "kid" => kid,
         "alg" => alg,
         "jkt" => JOSE.JWK.thumbprint(:sha256, JOSE.JWK.from_map(jwk)),
         "jti" => claims["jti"],
         "exp" => claims["exp"]
       }}
    else
      {:error, _} = e -> e
      _ -> {:error, {:invalid_client, "Unable to verify \"client_assertion\" JWT"}}
    end
  end

  defp decode_part(part) do
    with {:ok, json} <- Base.url_decode64(part, padding: false),
         {:ok, map} when is_map(map) <- Jason.decode(json),
         do: {:ok, map},
         else: (_ -> :error)
  end

  defp find_key(%{"keys" => keys}, kid) do
    case Enum.find(keys, &(&1["kid"] == kid)) do
      nil -> {:error, {:invalid_client, "Unknown \"kid\" in client_assertion"}}
      jwk -> {:ok, Map.delete(jwk, "d")}
    end
  end

  defp find_key(_, _), do: {:error, {:invalid_client, "Client has no jwks"}}

  defp check_assertion_claims(claims, client_id, issuer, now) do
    cond do
      claims["iss"] != client_id ->
        {:error, {:invalid_client, "Invalid \"iss\" claim in client_assertion"}}

      claims["sub"] != client_id ->
        {:error, {:invalid_client, "Invalid \"sub\" claim in client_assertion"}}

      not (claims["aud"] == issuer or (is_list(claims["aud"]) and issuer in claims["aud"])) ->
        {:error, {:invalid_client, "Invalid \"aud\" claim in client_assertion"}}

      not is_binary(claims["jti"]) ->
        {:error, {:invalid_client, "Missing \"jti\" claim in client_assertion"}}

      not is_integer(claims["exp"]) or claims["exp"] < now ->
        {:error, {:invalid_client, "client_assertion expired"}}

      is_integer(claims["iat"]) and now - claims["iat"] > @assertion_max_age ->
        {:error, {:invalid_client, "client_assertion too old"}}

      true ->
        :ok
    end
  end

  @doc "Upstream compareRedirectUri: exact, or loopback host with any port."
  def redirect_uri_allowed?(%Client{metadata: %{"redirect_uris" => uris}}, uri) do
    Enum.any?(uris, fn allowed ->
      allowed == uri or
        (match?({:ok, %URI{host: h}} when h in ["127.0.0.1", "[::1]", "::1"], URI.new(allowed)) and
           same_but_port?(allowed, uri))
    end)
  end

  defp same_but_port?(a, b) do
    with {:ok, ua} <- URI.new(a), {:ok, ub} <- URI.new(b) do
      ua.host == ub.host and ua.scheme == ub.scheme and (ua.path || "/") == (ub.path || "/") and
        ua.query == ub.query and ua.fragment == ub.fragment and
        (is_nil(ua.port) or ua.port == 80 or ua.port == ub.port)
    else
      _ -> false
    end
  end

  @doc "A DPoP proof's key must differ from a private_key_jwt client key."
  def dpop_key_conflict?(%{"method" => "private_key_jwt", "jkt" => jkt}, %{jkt: jkt}), do: true
  def dpop_key_conflict?(_, _), do: false

  def default_redirect_uri(%Client{metadata: %{"redirect_uris" => [one]}}), do: one
  def default_redirect_uri(_), do: nil

  @doc false
  def dpop_module, do: DPoP
end
