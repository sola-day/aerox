defmodule Aerox.PDS.Space.Credentials do
  @moduledoc """
  The Spaces tokens as the **published alpha** defines them (DESIGN §12.4;
  `@atproto/space` `credential.ts`, `SPACE_TOKEN_TYPES`) — three classes with
  one wire shape, differing in signer, audience and lifetime:

  * **delegation** (`typ: atproto-space-delegation+jwt`, `getDelegationToken`):
    `iss` = the user's DID, `sub` = the space URI, `aud` =
    `<spaceDid>#atproto_space_host`, 60 s, single use (`jti`); signed by the
    user's `#atproto` key (`kid: #atproto`).
  * **credential** (`typ: atproto-space-credential+jwt`, `getSpaceCredential`):
    `iss` = the space authority's DID, `sub` = the space URI, **no `aud`**
    (multi-use across repo hosts), `cnf.jkt` = the holder's DPoP key
    (required), 7200 s; signed by the authority's `#atproto` key (an authority
    hosted on a PDS has no separate `#atproto_space` key).
  * **client attestation** (`typ: atproto-client-attestation+jwt`): `iss` =
    `sub` = the OAuth `client_id`, `aud` = the space host, 60 s; signed by a
    key in the client's published JWKS. Only needed when the space's
    `appAccess` gates on app identity.

  The earlier `permissioned-data` branch (`space_member_grant` /
  `space_credential` with `clientId` claims) is not accepted: `bulletin`
  speaks the alpha. Verification resolves `iss` through the PDS identity
  cache to its `#atproto` key; the clock skew is 5 s as upstream.
  """
  alias Aerox.ATProto.Crypto

  @delegation_typ "atproto-space-delegation+jwt"
  @credential_typ "atproto-space-credential+jwt"
  @attestation_typ "atproto-client-attestation+jwt"
  @delegation_ttl 60
  @credential_ttl 7200
  @skew 5
  @replay_table :aerox_space_delegation_jti

  @type delegation :: %{
          iss: String.t(),
          sub: String.t(),
          aud: String.t(),
          exp: integer,
          jti: String.t()
        }
  @type credential :: %{
          iss: String.t(),
          sub: String.t(),
          jkt: String.t(),
          exp: integer,
          jti: String.t()
        }
  @type attestation :: %{client_id: String.t(), aud: String.t(), exp: integer, jti: String.t()}

  def delegation_typ, do: @delegation_typ
  def credential_typ, do: @credential_typ
  def attestation_typ, do: @attestation_typ

  @doc "Upstream `spaceHostAud`: how a space authority is addressed as the space host."
  @spec space_host_aud(String.t()) :: String.t()
  def space_host_aud(space_did), do: space_did <> "#atproto_space_host"

  @doc "Upstream `createSpaceToken('delegation', …)`."
  @spec create_delegation(map, Crypto.Keypair.t(), keyword) :: String.t()
  def create_delegation(%{iss: iss, space: space, aud: aud}, keypair, opts \\ []) do
    iat = Keyword.get(opts, :now, System.os_time(:second))

    jwt(
      @delegation_typ,
      "#atproto",
      %{
        "iss" => iss,
        "sub" => space,
        "aud" => aud,
        "iat" => iat,
        "exp" => iat + @delegation_ttl,
        "jti" => jti()
      },
      keypair
    )
  end

  @doc "Upstream `createSpaceToken('credential', …)`: bound to the holder's DPoP key."
  @spec create_credential(map, Crypto.Keypair.t(), keyword) :: String.t()
  def create_credential(%{iss: iss, space: space, jkt: jkt}, keypair, opts \\ [])
      when is_binary(jkt) do
    iat = Keyword.get(opts, :now, System.os_time(:second))
    ttl = Keyword.get(opts, :exp_seconds, @credential_ttl)

    jwt(
      @credential_typ,
      "#atproto",
      %{
        "iss" => iss,
        "sub" => space,
        "cnf" => %{"jkt" => jkt},
        "iat" => iat,
        "exp" => iat + ttl,
        "jti" => jti()
      },
      keypair
    )
  end

  @doc """
  Verifies a delegation token: typ, structure, expiry, signature under
  `iss`'s `#atproto` key, and — when given — `sub:` (the requested space)
  and `aud:` (this space host). Single use: a `jti` is accepted once.
  """
  @spec verify_delegation(String.t(), keyword) ::
          {:ok, delegation} | {:error, {String.t(), String.t()}}
  def verify_delegation(token, opts \\ []) do
    with {:ok, payload} <- verify(token, @delegation_typ, opts),
         {:ok, aud} <- fetch_string(payload, "aud", "BadJwtAudience"),
         :ok <-
           check_expected(
             aud,
             opts[:aud],
             {"BadJwtAudience", "token audience does not match this service"}
           ),
         :ok <-
           check_expected(
             payload["sub"],
             opts[:sub],
             {"BadJwtSub", "token subject does not match the requested space"}
           ),
         {:ok, jti} <- fetch_string(payload, "jti", "BadJwt"),
         :ok <- check_replay(jti, payload["exp"], Keyword.get(opts, :replay, true)) do
      {:ok, %{iss: payload["iss"], sub: payload["sub"], aud: aud, exp: payload["exp"], jti: jti}}
    end
  end

  @doc "Verifies a space credential: typ, structure (`cnf.jkt` required), expiry, signature."
  @spec verify_credential(String.t(), keyword) ::
          {:ok, credential} | {:error, {String.t(), String.t()}}
  def verify_credential(token, opts \\ []) do
    with {:ok, payload} <- verify(token, @credential_typ, opts),
         jkt when is_binary(jkt) and jkt != "" <-
           get_in(payload, ["cnf", "jkt"]) || {:error, {"BadJwtCnf", "missing token \"cnf.jkt\""}} do
      {:ok,
       %{
         iss: payload["iss"],
         sub: payload["sub"],
         jkt: jkt,
         exp: payload["exp"],
         jti: payload["jti"]
       }}
    end
  end

  @doc """
  Verifies a client attestation against the client's published JWKS
  (`jwks` is a JWK set map): typ, `iss == sub` (the client_id), `aud:`,
  expiry, signature (by `kid` when the set has several keys).
  """
  @spec verify_attestation(String.t(), map, keyword) ::
          {:ok, attestation} | {:error, {String.t(), String.t()}}
  def verify_attestation(token, %{"keys" => keys}, opts \\ []) when is_list(keys) do
    now = Keyword.get(opts, :now, System.os_time(:second))

    with {:ok, header, payload} <- peek(token),
         :ok <- check_typ(header, @attestation_typ),
         {:ok, iss} <- fetch_string(payload, "iss", "BadJwtIss"),
         true <-
           payload["sub"] == iss ||
             {:error,
              {"BadJwtIss", "client attestation \"iss\" and \"sub\" must both be the client_id"}},
         {:ok, aud} <- fetch_string(payload, "aud", "BadJwtAudience"),
         :ok <-
           check_expected(
             aud,
             opts[:aud],
             {"BadJwtAudience", "token audience does not match this service"}
           ),
         :ok <- check_exp(payload, now),
         {:ok, jti} <- fetch_string(payload, "jti", "BadJwt"),
         {:ok, jwk} <- find_key(keys, header["kid"]),
         :ok <- check_jose_sig(jwk, header["alg"], token) do
      {:ok, %{client_id: iss, aud: aud, exp: payload["exp"], jti: jti}}
    end
  end

  @doc "The unverified header and payload of a JWT."
  @spec peek(String.t()) :: {:ok, map, map} | {:error, {String.t(), String.t()}}
  def peek(token) do
    with [h, p, _] <- String.split(token, "."),
         {:ok, hj} <- Base.url_decode64(h, padding: false),
         {:ok, pj} <- Base.url_decode64(p, padding: false),
         {:ok, header} when is_map(header) <- Jason.decode(hj),
         {:ok, payload} when is_map(payload) <- Jason.decode(pj) do
      {:ok, header, payload}
    else
      _ -> {:error, {"BadJwt", "malformed token: expected 3 parts"}}
    end
  end

  # ------------------------------------------------------------- internals

  # upstream parseSpaceToken + verifySpaceToken (with a key-rotation retry)
  defp verify(token, typ, opts) do
    now = Keyword.get(opts, :now, System.os_time(:second))
    resolve = Keyword.get(opts, :resolve_key, &default_resolve/2)

    with {:ok, [h, p, s]} <- three_parts(token),
         {:ok, header, payload} <- peek(token),
         :ok <- check_typ(header, typ),
         {:ok, _} <- fetch_string(header, "alg", "BadJwt"),
         {:ok, iss} <- fetch_string(payload, "iss", "BadJwtIss"),
         {:ok, _} <- fetch_string(payload, "sub", "BadJwtSub"),
         :ok <- check_exp(payload, now),
         {:ok, sig} <- decode_sig(s),
         :ok <- check_sig(iss, header["alg"], h <> "." <> p, sig, resolve) do
      {:ok, payload}
    end
  end

  defp three_parts(token) do
    case String.split(token, ".") do
      [_, _, _] = parts -> {:ok, parts}
      _ -> {:error, {"BadJwt", "malformed token: expected 3 parts"}}
    end
  end

  defp check_typ(%{"typ" => typ}, typ), do: :ok

  defp check_typ(header, typ),
    do:
      {:error, {"BadJwtType", "wrong token type: expected \"#{typ}\", got \"#{header["typ"]}\""}}

  defp check_exp(%{"exp" => exp}, now) when is_integer(exp) do
    if now - @skew >= exp, do: {:error, {"JwtExpired", "token expired"}}, else: :ok
  end

  defp check_exp(_, _), do: {:error, {"BadJwt", "missing token \"exp\""}}

  defp check_expected(_actual, nil, _err), do: :ok
  defp check_expected(actual, actual, _err), do: :ok
  defp check_expected(_, _, err), do: {:error, err}

  defp decode_sig(s) do
    case Base.url_decode64(s, padding: false) do
      {:ok, sig} -> {:ok, sig}
      :error -> {:error, {"BadJwtSignature", "invalid token signature"}}
    end
  end

  defp check_sig(iss, alg, signing_input, sig, resolve) do
    with {:ok, key} <- resolve_key(iss, false, resolve) do
      cond do
        valid_sig?(key, alg, signing_input, sig) ->
          :ok

        match?({:ok, fresh} when fresh != key, resolve_key(iss, true, resolve)) and
            valid_sig?(elem(resolve_key(iss, true, resolve), 1), alg, signing_input, sig) ->
          :ok

        true ->
          {:error, {"BadJwtSignature", "invalid token signature"}}
      end
    end
  end

  defp resolve_key(iss, force, resolve) do
    case resolve.(iss, force) do
      {:ok, key} -> {:ok, key}
      _ -> {:error, {"BadJwtSignature", "could not resolve token issuer"}}
    end
  end

  defp valid_sig?(did_key, alg, signing_input, sig) do
    case Crypto.did_key_alg(did_key) do
      {:ok, ^alg} -> Crypto.verify_did_sig(did_key, signing_input, sig)
      _ -> false
    end
  end

  defp fetch_string(map, key, err) do
    case map[key] do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {err, "missing token \"#{key}\""}}
    end
  end

  defp default_resolve(iss, force) do
    did = iss |> String.split("#", parts: 2) |> hd()
    Aerox.Identity.resolve_signing_key(Aerox.PDS.Identity, did, force: force)
  end

  defp find_key([jwk], nil), do: {:ok, jwk}

  defp find_key(keys, kid) do
    case Enum.find(keys, &(&1["kid"] == kid)) do
      nil -> {:error, {"BadJwtSignature", "no client key matches the attestation"}}
      jwk -> {:ok, jwk}
    end
  end

  defp check_jose_sig(jwk, alg, token) when is_binary(alg) do
    try do
      case JOSE.JWS.verify_strict(JOSE.JWK.from_map(jwk), [alg], token) do
        {true, _, _} -> :ok
        _ -> {:error, {"BadJwtSignature", "invalid token signature"}}
      end
    rescue
      _ -> {:error, {"BadJwtSignature", "invalid client key"}}
    end
  end

  defp check_jose_sig(_, _, _), do: {:error, {"BadJwt", "missing token \"alg\""}}

  # a delegation token is consumed once (upstream: singleUse)
  defp check_replay(_jti, _exp, false), do: :ok

  defp check_replay(jti, exp, true) do
    table = replay_table()
    now = System.os_time(:second)

    if :rand.uniform(50) == 1,
      do: :ets.select_delete(table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])

    if :ets.insert_new(table, {jti, (is_integer(exp) && exp) || now + @delegation_ttl}),
      do: :ok,
      else: {:error, {"BadJwtReplay", "delegation token already used"}}
  end

  defp replay_table do
    case :ets.whereis(@replay_table) do
      :undefined ->
        try do
          :ets.new(@replay_table, [:named_table, :public, :set, write_concurrency: true])
        rescue
          ArgumentError -> @replay_table
        end

      _ ->
        @replay_table
    end
  end

  defp jwt(typ, kid, payload, keypair) do
    header = %{"alg" => Crypto.jwt_alg(keypair), "typ" => typ, "kid" => kid}
    signing_input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(payload))
    signing_input <> "." <> b64(Crypto.sign(keypair, signing_input))
  end

  # upstream randomStr(16, 'hex')
  defp jti, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end
