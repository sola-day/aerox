defmodule Aerox.Auth.DPoP do
  @moduledoc """
  DPoP (RFC 9449) as upstream `@atproto/oauth-provider` implements it, shared
  by OAuth (DESIGN §11.2) and Spaces credentials (§12.4):

  * **Nonces** are HMAC-SHA256(secret, counter) where the counter is
    `now / rotation_interval`; a proof may carry the previous, current or
    next nonce, and every response advertises the *next* one in
    `DPoP-Nonce` (`next_nonce/0`).
  * **Proofs** are `dpop+jwt` JWS with the public key embedded in the `jwk`
    header: `jti` required, `htm` = the request method, `htu` = the
    request URL without query/fragment, `nonce` when the server issues
    nonces, `ath` = base64url(sha256(access token)) when one accompanies
    the proof (and forbidden otherwise), `iat` within 10 s of now (with
    the nonce window as clock tolerance). The verified proof's `jkt` is the
    RFC 7638 thumbprint the token is bound to.
  * **Replay**: a `jti` is accepted once per nonce window (ETS).
  """
  use GenServer

  @nonce_max_age_ms 3 * 60 * 1000
  @proof_max_age_s 10
  @replay_table __MODULE__.Replay
  @algs ~w(ES256 ES256K ES384 ES512 RS256 RS384 RS512 PS256 PS384 PS512 EdDSA)

  @type proof :: %{jti: String.t(), jkt: String.t(), htm: String.t(), htu: String.t()}

  # ------------------------------------------------------------- nonces

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    secret = Keyword.get(opts, :secret) || config(:secret) || :crypto.strong_rand_bytes(32)

    secret =
      if is_binary(secret) and byte_size(secret) == 64,
        do: Base.decode16!(secret, case: :mixed),
        else: secret

    interval =
      Keyword.get(opts, :rotation_interval_ms) || config(:rotation_interval_ms) ||
        div(@nonce_max_age_ms, 3)

    :ets.new(@replay_table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{secret: secret, interval: interval}}
  end

  defp config(key), do: Application.get_env(:aerox, __MODULE__, [])[key]

  @doc "The nonce clients should use next (advertised in `DPoP-Nonce`)."
  def next_nonce(server \\ __MODULE__), do: GenServer.call(server, :next_nonce)

  @doc "Is `nonce` the previous, current or next nonce?"
  def valid_nonce?(nonce, server \\ __MODULE__), do: GenServer.call(server, {:check, nonce})

  @impl true
  def handle_call(:next_nonce, _from, state),
    do: {:reply, compute(state, counter(state) + 1), state}

  def handle_call({:check, nonce}, _from, state) do
    c = counter(state)
    {:reply, Enum.any?([c - 1, c, c + 1], &(compute(state, &1) == nonce)), state}
  end

  defp counter(%{interval: interval}), do: div(System.os_time(:millisecond), interval)

  defp compute(%{secret: secret}, counter),
    do: :crypto.mac(:hmac, :sha256, secret, <<counter::64>>) |> Base.url_encode64(padding: false)

  # -------------------------------------------------------------- proofs

  @doc """
  Verifies the `DPoP` header of a request. `opts`: `:access_token` (binds
  `ath`), `:nonces` (default true; the server issues nonces), `:server`,
  `:now` (seconds). Returns `{:ok, proof}`, `{:ok, nil}` when no header is
  present, `{:error, :use_dpop_nonce}` (answer with a fresh nonce), or
  `{:error, {:invalid_dpop_proof, message}}`.
  """
  @spec verify(String.t() | nil, String.t(), String.t(), keyword) ::
          {:ok, proof | nil} | {:error, term}
  def verify(header, method, url, opts \\ [])
  def verify(nil, _method, _url, _opts), do: {:ok, nil}
  def verify("", _, _, _), do: {:error, {:invalid_dpop_proof, "DPoP header cannot be empty"}}

  def verify(token, method, url, opts) when is_binary(token) do
    now = Keyword.get(opts, :now, System.os_time(:second))

    with {:ok, header, payload} <- decode(token),
         :ok <- check_header(header),
         {:ok, jwk} <- embedded_jwk(header),
         :ok <- check_signature(jwk, header["alg"], token),
         :ok <- check_iat(payload, now),
         :ok <- check_claims(payload, method, url, opts),
         {:ok, jkt} <- thumbprint(jwk),
         :ok <- unique_jti(payload["jti"]) do
      {:ok,
       %{jti: payload["jti"], jkt: jkt, htm: payload["htm"], htu: normalize_htu(payload["htu"])}}
    end
  end

  defp decode(token) do
    with [h, p, _] <- String.split(token, "."),
         {:ok, hj} <- Base.url_decode64(h, padding: false),
         {:ok, pj} <- Base.url_decode64(p, padding: false),
         {:ok, header} when is_map(header) <- Jason.decode(hj),
         {:ok, payload} when is_map(payload) <- Jason.decode(pj) do
      {:ok, header, payload}
    else
      _ -> {:error, {:invalid_dpop_proof, "Failed to verify DPoP proof: malformed JWT"}}
    end
  end

  defp check_header(%{"typ" => "dpop+jwt", "alg" => alg}) when alg in @algs, do: :ok

  defp check_header(%{"typ" => "dpop+jwt"}),
    do: {:error, {:invalid_dpop_proof, "Failed to verify DPoP proof: unsupported alg"}}

  defp check_header(_),
    do:
      {:error,
       {:invalid_dpop_proof, "Failed to verify DPoP proof: unexpected \"typ\" JWT header value"}}

  defp embedded_jwk(%{"jwk" => jwk}) when is_map(jwk) do
    if Map.has_key?(jwk, "d"),
      do:
        {:error, {:invalid_dpop_proof, "Failed to verify DPoP proof: private key in jwk header"}},
      else: {:ok, jwk}
  end

  defp embedded_jwk(_),
    do: {:error, {:invalid_dpop_proof, "Failed to verify DPoP proof: missing jwk header"}}

  defp check_signature(jwk, alg, token) do
    try do
      case JOSE.JWS.verify_strict(JOSE.JWK.from_map(jwk), [alg], token) do
        {true, _, _} ->
          :ok

        _ ->
          {:error,
           {:invalid_dpop_proof, "Failed to verify DPoP proof: signature verification failed"}}
      end
    rescue
      _ -> {:error, {:invalid_dpop_proof, "Failed to verify DPoP proof: invalid jwk"}}
    end
  end

  defp check_iat(%{"iat" => iat}, now) when is_integer(iat) do
    tolerance = div(@nonce_max_age_ms, 1000)

    cond do
      iat > now + tolerance ->
        {:error,
         {:invalid_dpop_proof,
          "Failed to verify DPoP proof: \"iat\" claim timestamp check failed (it should be in the past)"}}

      now - iat > @proof_max_age_s + tolerance ->
        {:error,
         {:invalid_dpop_proof,
          "Failed to verify DPoP proof: \"iat\" claim timestamp check failed (too far in the past)"}}

      true ->
        :ok
    end
  end

  defp check_iat(_, _),
    do: {:error, {:invalid_dpop_proof, "Failed to verify DPoP proof: missing \"iat\" claim"}}

  defp check_claims(payload, method, url, opts) do
    nonces? = Keyword.get(opts, :nonces, true)
    server = Keyword.get(opts, :server, __MODULE__)
    access_token = Keyword.get(opts, :access_token)

    cond do
      not is_binary(payload["jti"]) or payload["jti"] == "" ->
        {:error, {:invalid_dpop_proof, "DPoP \"jti\" missing"}}

      payload["htm"] != method ->
        {:error, {:invalid_dpop_proof, "DPoP \"htm\" mismatch"}}

      not is_binary(payload["htu"]) ->
        {:error, {:invalid_dpop_proof, "Invalid DPoP \"htu\" type"}}

      normalize_htu(payload["htu"]) != normalize_htu(url) ->
        {:error, {:invalid_dpop_proof, "DPoP \"htu\" mismatch"}}

      payload["nonce"] != nil and not is_binary(payload["nonce"]) ->
        {:error, {:invalid_dpop_proof, "Invalid DPoP \"nonce\" type"}}

      nonces? and is_nil(payload["nonce"]) ->
        {:error, :use_dpop_nonce}

      nonces? and not valid_nonce?(payload["nonce"], server) ->
        {:error, :use_dpop_nonce}

      access_token != nil and payload["ath"] != ath(access_token) ->
        {:error, {:invalid_dpop_proof, "DPoP \"ath\" mismatch"}}

      is_nil(access_token) and payload["ath"] != nil ->
        {:error, {:invalid_dpop_proof, "DPoP \"ath\" claim not allowed"}}

      true ->
        :ok
    end
  end

  @doc "base64url(sha256(access token)), the `ath` claim."
  def ath(access_token),
    do: :crypto.hash(:sha256, access_token) |> Base.url_encode64(padding: false)

  @doc "RFC 9449 §4.3: scheme-based and syntax-based normalization; query and fragment dropped (upstream allows them in the proof for legacy clients)."
  def normalize_htu(htu) when is_binary(htu) do
    case URI.new(htu) do
      {:ok, %URI{scheme: s, host: h, port: p, path: path, userinfo: nil}}
      when s in ["http", "https"] and is_binary(h) ->
        default = if s == "https", do: 443, else: 80
        port = if p && p != default, do: ":#{p}", else: ""
        "#{s}://#{String.downcase(h)}#{port}#{normalize_path(path)}"

      _ ->
        nil
    end
  end

  def normalize_htu(_), do: nil

  defp normalize_path(nil), do: "/"
  defp normalize_path(""), do: "/"

  defp normalize_path(path) do
    # remove dot segments (RFC 3986 §5.2.4)
    segments =
      path
      |> String.split("/")
      |> Enum.reduce([], fn
        ".", acc -> acc
        "..", [] -> []
        "..", acc -> tl(acc)
        seg, acc -> [seg | acc]
      end)
      |> Enum.reverse()

    out = Enum.join(segments, "/")
    if String.starts_with?(out, "/"), do: out, else: "/" <> out
  end

  @doc "RFC 7638 JWK thumbprint (sha256, base64url)."
  def thumbprint(jwk) do
    try do
      {:ok, JOSE.JWK.thumbprint(:sha256, JOSE.JWK.from_map(jwk))}
    rescue
      _ -> {:error, {:invalid_dpop_proof, "Failed to calculate jkt"}}
    end
  end

  defp unique_jti(jti) do
    now = System.os_time(:millisecond)
    ttl = trunc(@nonce_max_age_ms * 1.1)

    if :rand.uniform(200) == 1,
      do: :ets.select_delete(@replay_table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])

    if :ets.insert_new(@replay_table, {jti, now + ttl}),
      do: :ok,
      else: {:error, {:invalid_dpop_proof, "DPoP proof replayed"}}
  end

  # ------------------------------------------------------------- helpers

  @doc "The `WWW-Authenticate` value for a DPoP challenge (upstream WWWAuthenticateError)."
  def www_authenticate(:use_dpop_nonce),
    do:
      ~s(DPoP error="use_dpop_nonce", error_description="Authorization server requires nonce in DPoP proof")

  def www_authenticate({:invalid_dpop_proof, msg}),
    do: ~s(DPoP error="invalid_dpop_proof", error_description="#{String.replace(msg, "\"", "'")}")
end
