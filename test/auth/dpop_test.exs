defmodule Aerox.Auth.DPoPTest do
  use ExUnit.Case, async: false
  alias Aerox.Auth.DPoP

  setup_all do
    {:ok, pid} = DPoP.start_link(name: :dpop_test, secret: :crypto.strong_rand_bytes(32))
    {:ok, server: pid}
  end

  defp key, do: JOSE.JWK.generate_key({:ec, "P-256"})

  defp proof(jwk, claims, opts \\ []) do
    {_, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()

    header = %{
      "alg" => Keyword.get(opts, :alg, "ES256"),
      "typ" => Keyword.get(opts, :typ, "dpop+jwt"),
      "jwk" => public
    }

    claims =
      Map.merge(
        %{
          "jti" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false),
          "iat" => System.os_time(:second)
        },
        claims
      )

    {_, token} = JOSE.JWS.sign(jwk, Jason.encode!(claims), header) |> JOSE.JWS.compact()
    token
  end

  test "nonces rotate and the previous/current/next are accepted", %{server: server} do
    n = DPoP.next_nonce(server)
    assert DPoP.valid_nonce?(n, server)
    refute DPoP.valid_nonce?("nope", server)
  end

  test "a valid proof yields its jkt; every RFC 9449 check is enforced", %{server: server} do
    jwk = key()
    url = "https://pds.aerox.sola.town/oauth/token"
    nonce = DPoP.next_nonce(server)
    base = %{"htm" => "POST", "htu" => url, "nonce" => nonce}

    assert {:ok, %{jkt: jkt, htm: "POST", htu: ^url}} =
             DPoP.verify(proof(jwk, base), "POST", url, server: server)

    {:ok, ^jkt} = DPoP.thumbprint(jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map() |> elem(1))

    # replay of the same jti
    p = proof(jwk, base)
    assert {:ok, _} = DPoP.verify(p, "POST", url, server: server)

    assert {:error, {:invalid_dpop_proof, "DPoP proof replayed"}} =
             DPoP.verify(p, "POST", url, server: server)

    assert {:error, {:invalid_dpop_proof, "DPoP \"htm\" mismatch"}} =
             DPoP.verify(proof(jwk, base), "GET", url, server: server)

    assert {:error, {:invalid_dpop_proof, "DPoP \"htu\" mismatch"}} =
             DPoP.verify(proof(jwk, base), "POST", "https://pds.aerox.sola.town/oauth/par",
               server: server
             )

    # query and fragment in htu are tolerated (legacy clients), port/case normalised
    assert {:ok, _} =
             DPoP.verify(
               proof(jwk, %{base | "htu" => "https://PDS.aerox.sola.town:443/oauth/token?x=1#f"}),
               "POST",
               url,
               server: server
             )

    assert {:error, :use_dpop_nonce} =
             DPoP.verify(proof(jwk, Map.delete(base, "nonce")), "POST", url, server: server)

    assert {:error, :use_dpop_nonce} =
             DPoP.verify(proof(jwk, %{base | "nonce" => "stale"}), "POST", url, server: server)

    assert {:ok, _} =
             DPoP.verify(proof(jwk, Map.delete(base, "nonce")), "POST", url,
               server: server,
               nonces: false
             )

    assert {:error, {:invalid_dpop_proof, "DPoP \"jti\" missing"}} =
             DPoP.verify(proof(jwk, Map.put(base, "jti", "")), "POST", url, server: server)

    assert {:error, {:invalid_dpop_proof, msg}} =
             DPoP.verify(proof(jwk, base, typ: "JWT"), "POST", url, server: server)

    assert msg =~ "typ"

    assert {:error, {:invalid_dpop_proof, msg}} =
             DPoP.verify(
               proof(jwk, Map.put(base, "iat", System.os_time(:second) - 1000)),
               "POST",
               url,
               server: server
             )

    assert msg =~ "iat"

    # a proof signed by another key than the embedded one fails
    other = key()
    {_, public} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()

    {_, forged} =
      JOSE.JWS.sign(
        other,
        Jason.encode!(Map.merge(base, %{"jti" => "x1", "iat" => System.os_time(:second)})),
        %{"alg" => "ES256", "typ" => "dpop+jwt", "jwk" => public}
      )
      |> JOSE.JWS.compact()

    assert {:error, {:invalid_dpop_proof, msg}} = DPoP.verify(forged, "POST", url, server: server)
    assert msg =~ "signature"

    # ath binds the access token
    token = "access-token-bytes"

    assert {:ok, _} =
             DPoP.verify(proof(jwk, Map.put(base, "ath", DPoP.ath(token))), "POST", url,
               server: server,
               access_token: token
             )

    assert {:error, {:invalid_dpop_proof, "DPoP \"ath\" mismatch"}} =
             DPoP.verify(proof(jwk, base), "POST", url, server: server, access_token: token)

    assert {:error, {:invalid_dpop_proof, "DPoP \"ath\" claim not allowed"}} =
             DPoP.verify(proof(jwk, Map.put(base, "ath", "x")), "POST", url, server: server)

    assert {:ok, nil} = DPoP.verify(nil, "POST", url)
  end
end
