defmodule Aerox.Auth.ServiceJWT do
  @moduledoc """
  Inter-service JWTs (DESIGN §11.3, §20.2): issued by a PDS with the user's
  repo signing key (`iss` = user DID, `aud` = service DID, `lxm` = the NSID
  being called, ≤ 1 h) and verified identically everywhere:

  1. `alg` must be ES256K or ES256;
  2. `iss` → the DID's signing key (resolved through the given cache), the
     signature verified, high-S rejected (the kernel does that);
  3. `aud` must equal *this* service's DID;
  4. `exp` in the future with ≤ 60 s skew, `iat` not in the future, total
     lifetime ≤ 1 h;
  5. `lxm`, when required, must equal the method;
  6. `jti` must be unseen: an ETS replay set with TTL.
  """
  alias Aerox.ATProto.Crypto

  @max_lifetime 3600
  @skew 60
  @replay_table :aerox_service_jwt_jti

  @type claims :: %{
          iss: String.t(),
          aud: String.t(),
          exp: integer,
          iat: integer,
          lxm: String.t() | nil,
          jti: String.t() | nil
        }

  @doc "Creates a service JWT signed with `keypair`. `exp` defaults to now + 60 s."
  @spec create(keyword) :: String.t()
  def create(opts) do
    keypair = Keyword.fetch!(opts, :keypair)
    iat = Keyword.get(opts, :iat, System.os_time(:second))
    exp = Keyword.get(opts, :exp, iat + 60)

    header = %{"typ" => "JWT", "alg" => Crypto.jwt_alg(keypair)}

    payload =
      %{
        "iat" => iat,
        "iss" => Keyword.fetch!(opts, :iss),
        "aud" => Keyword.fetch!(opts, :aud),
        "exp" => exp,
        "jti" => Keyword.get(opts, :jti, random_jti())
      }
      |> then(&if(lxm = Keyword.get(opts, :lxm), do: Map.put(&1, "lxm", lxm), else: &1))

    signing_input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(payload))
    signing_input <> "." <> Base.url_encode64(Crypto.sign(keypair, signing_input), padding: false)
  end

  @doc """
  Verifies a service JWT. `resolve_key` is `(iss, force_refresh?) -> {:ok, did_key} | {:error, _}`;
  `own_did` is this service's DID (or `nil` to skip the audience check, as
  upstream allows); `lxm` is the required method (or `nil`).
  """
  @spec verify(
          String.t(),
          String.t() | nil,
          String.t() | nil,
          (String.t(), boolean -> {:ok, String.t()} | {:error, term}),
          keyword
        ) ::
          {:ok, claims} | {:error, {String.t(), String.t()}}
  def verify(jwt, own_did, lxm, resolve_key, opts \\ []) do
    now = Keyword.get(opts, :now, System.os_time(:second))

    with {:ok, [h, p, s]} <- split(jwt),
         {:ok, header} <- decode_json(h, "BadJwt"),
         {:ok, payload} <- decode_json(p, "BadJwt"),
         :ok <- check_typ(header),
         :ok <- check_alg(header),
         :ok <- check_times(payload, now),
         :ok <- check_aud(payload, own_did),
         :ok <- check_lxm(payload, lxm),
         {:ok, iss} <- check_iss(payload),
         {:ok, sig} <-
           Base.url_decode64(s, padding: false)
           |> then(
             &if(match?({:ok, _}, &1),
               do: &1,
               else: {:error, {"BadJwtSignature", "could not decode signature"}}
             )
           ),
         :ok <- check_sig(iss, h <> "." <> p, sig, header["alg"], resolve_key),
         :ok <- check_replay(payload, now, Keyword.get(opts, :replay, true)) do
      {:ok,
       %{
         iss: iss,
         aud: payload["aud"],
         exp: payload["exp"],
         iat: payload["iat"],
         lxm: payload["lxm"],
         jti: payload["jti"]
       }}
    end
  end

  defp split(jwt) do
    case String.split(jwt, ".") do
      [_, _, _] = parts -> {:ok, parts}
      _ -> {:error, {"BadJwt", "poorly formatted jwt"}}
    end
  end

  defp decode_json(part, name) do
    with {:ok, bytes} <- Base.url_decode64(part, padding: false),
         {:ok, %{} = json} <- Jason.decode(bytes) do
      {:ok, json}
    else
      _ -> {:error, {name, "poorly formatted jwt"}}
    end
  end

  defp check_typ(%{"typ" => typ}) when typ in ["at+jwt", "refresh+jwt", "dpop+jwt"],
    do: {:error, {"BadJwtType", "Invalid jwt type \"#{typ}\""}}

  defp check_typ(_), do: :ok

  defp check_alg(%{"alg" => alg}) when alg in ["ES256K", "ES256"], do: :ok
  defp check_alg(_), do: {:error, {"BadJwtAlg", "unsupported jwt alg"}}

  defp check_times(%{"exp" => exp} = payload, now) when is_integer(exp) do
    iat = payload["iat"]

    cond do
      now > exp + @skew ->
        {:error, {"JwtExpired", "jwt expired"}}

      is_integer(iat) and iat > now + @skew ->
        {:error, {"BadJwtIat", "jwt issued in the future"}}

      is_integer(iat) and exp - iat > @max_lifetime ->
        {:error, {"BadJwtExp", "jwt lifetime exceeds one hour"}}

      true ->
        :ok
    end
  end

  defp check_times(_, _), do: {:error, {"JwtExpired", "jwt has no expiration"}}

  defp check_aud(_payload, nil), do: :ok
  defp check_aud(%{"aud" => aud}, own) when aud == own, do: :ok

  defp check_aud(_, _),
    do: {:error, {"BadJwtAudience", "jwt audience does not match service did"}}

  defp check_lxm(_payload, nil), do: :ok
  defp check_lxm(%{"lxm" => lxm}, lxm), do: :ok

  defp check_lxm(%{"lxm" => _}, lxm),
    do: {:error, {"BadJwtLexiconMethod", "bad jwt lexicon method (\"lxm\"). must match: #{lxm}"}}

  defp check_lxm(_, lxm),
    do:
      {:error,
       {"BadJwtLexiconMethod", "missing jwt lexicon method (\"lxm\"). must match: #{lxm}"}}

  defp check_iss(%{"iss" => iss}) when is_binary(iss) do
    did = iss |> String.split("#", parts: 2) |> hd()

    if Aerox.ATProto.Syntax.valid_did?(did),
      do: {:ok, iss},
      else: {:error, {"BadJwtIss", "jwt iss is not a valid did"}}
  end

  defp check_iss(_), do: {:error, {"BadJwtIss", "jwt iss is not a valid did"}}

  # Verify with the cached key; on failure refetch the key once (rotation).
  defp check_sig(iss, msg, sig, alg, resolve_key) do
    with {:ok, key} <- resolve(iss, false, resolve_key) do
      if valid_sig?(key, msg, sig, alg) do
        :ok
      else
        case resolve(iss, true, resolve_key) do
          {:ok, fresh} when fresh != key ->
            if valid_sig?(fresh, msg, sig, alg),
              do: :ok,
              else: {:error, {"BadJwtSignature", "jwt signature does not match jwt issuer"}}

          _ ->
            {:error, {"BadJwtSignature", "jwt signature does not match jwt issuer"}}
        end
      end
    end
  end

  defp resolve(iss, force, resolve_key) do
    case resolve_key.(iss, force) do
      {:ok, key} -> {:ok, key}
      {:error, _} -> {:error, {"BadJwtSignature", "could not resolve iss did"}}
    end
  end

  defp valid_sig?(did_key, msg, sig, alg) do
    case Crypto.did_key_alg(did_key) do
      {:ok, ^alg} -> Crypto.verify_did_sig(did_key, msg, sig)
      _ -> false
    end
  end

  defp check_replay(_payload, _now, false), do: :ok

  defp check_replay(%{"jti" => jti, "exp" => exp}, now, true) when is_binary(jti) do
    table = replay_table()
    sweep(table, now)

    if :ets.insert_new(table, {jti, exp}),
      do: :ok,
      else: {:error, {"BadJwtReplay", "jwt jti has already been used"}}
  end

  defp check_replay(_, _, _), do: :ok

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

  # cheap probabilistic sweep of expired jtis
  defp sweep(table, now) do
    if :rand.uniform(100) == 1,
      do: :ets.select_delete(table, [{{:_, :"$1"}, [{:<, :"$1", now - @skew}], [true]}])
  end

  defp random_jti, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  defp b64(str), do: Base.url_encode64(str, padding: false)
end
