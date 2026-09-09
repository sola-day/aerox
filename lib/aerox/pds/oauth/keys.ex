defmodule Aerox.PDS.OAuth.Keys do
  @moduledoc """
  The authorization server's signing keyset (DESIGN §11.2): one P-256 key
  from `config :aerox, Aerox.PDS, oauth_key_hex:` (32 bytes), `kid` = its
  RFC 7638 thumbprint, published at `/oauth/jwks`. Access tokens and
  ephemeral tokens are ES256 JWTs signed here; verification uses the same
  key by `kid`.
  """
  alias Aerox.PDS.Config

  @doc "The private JWK (JOSE struct), cached in persistent_term."
  def private_jwk do
    case :persistent_term.get({__MODULE__, :jwk}, nil) do
      nil ->
        hex =
          Config.get(:oauth_key_hex) ||
            raise("config :aerox, Aerox.PDS, oauth_key_hex: is required")

        d = Base.decode16!(hex, case: :mixed)

        {<<4, x::binary-size(32), y::binary-size(32)>>, ^d} =
          :crypto.generate_key(:ecdh, :secp256r1, d)

        b64 = &Base.url_encode64(&1, padding: false)
        map = %{"kty" => "EC", "crv" => "P-256", "x" => b64.(x), "y" => b64.(y), "d" => b64.(d)}
        jwk = JOSE.JWK.from_map(map)
        kid = JOSE.JWK.thumbprint(:sha256, jwk)

        jwk = %{
          jwk
          | fields: Map.merge(jwk.fields, %{"kid" => kid, "use" => "sig", "alg" => "ES256"})
        }

        :persistent_term.put({__MODULE__, :jwk}, jwk)
        jwk

      jwk ->
        jwk
    end
  end

  def kid, do: private_jwk().fields["kid"]

  @doc "The public JWKS document."
  def public_jwks do
    {_, map} = private_jwk() |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    %{"keys" => [Map.merge(map, %{"kid" => kid(), "use" => "sig", "alg" => "ES256"})]}
  end

  @doc "A compact ES256 JWT with `typ` and the keyset's `kid`."
  def sign(payload, typ) do
    header = %{"alg" => "ES256", "typ" => typ, "kid" => kid()}

    {_, token} =
      JOSE.JWS.sign(private_jwk(), Jason.encode!(payload), header) |> JOSE.JWS.compact()

    token
  end

  @doc "Verifies a JWT signed by this keyset; returns `{:ok, header, claims}`."
  def verify(token) do
    with [h, _, _] <- String.split(token, "."),
         {:ok, hj} <- Base.url_decode64(h, padding: false),
         {:ok, header} <- Jason.decode(hj),
         true <- header["kid"] in [nil, kid()] and header["alg"] == "ES256",
         {true, payload, _} <- JOSE.JWS.verify_strict(private_jwk(), ["ES256"], token),
         {:ok, claims} <- Jason.decode(payload) do
      {:ok, header, claims}
    else
      _ -> {:error, :invalid_signature}
    end
  end
end
