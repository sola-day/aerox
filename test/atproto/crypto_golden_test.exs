defmodule Aerox.ATProto.CryptoGoldenTest do
  @moduledoc "L3 (VERIFICATION §3.1): interop crypto vectors, did:key vectors, low-S and DER negatives, property: every signature is low-S."
  use Aerox.GoldenCase, async: true
  use ExUnitProperties
  alias Aerox.ATProto.{Base58, Crypto}

  test "signature fixtures: valid low-S verify; high-S and DER fail" do
    for f <- json_golden!("crypto/signature-fixtures.json") do
      msg = Base.decode64!(f["messageBase64"], padding: false)
      sig = Base.decode64!(f["signatureBase64"], padding: false)

      assert Crypto.verify_did_sig(f["publicKeyDid"], msg, sig) == f["validSignature"],
             f["comment"]

      # the legacy (unprefixed) multibase plus the 2019 suite name yields the same did:key
      {:ok, curve, _key} = Crypto.parse_did_key(f["publicKeyDid"])

      assert {:ok, f["publicKeyDid"]} ==
               Crypto.did_key_from_verification_method(f["didDocSuite"], f["publicKeyMultibase"])

      assert Crypto.jwt_alg(curve) == f["algorithm"]
    end
  end

  test "w3c did:key vectors, secp256k1: private key hex → did:key" do
    for v <- json_golden!("crypto/w3c_didkey_K256.json") do
      kp = Crypto.import(:k256, v["privateKeyBytesHex"])
      assert Crypto.did_key(kp) == v["publicDidKey"]
      assert {:ok, :k256, pub} = Crypto.parse_did_key(v["publicDidKey"])
      assert pub == kp.public
      assert Crypto.format_did_key(:k256, pub) == v["publicDidKey"]
    end
  end

  test "w3c did:key vectors, P-256: private key base58 → did:key" do
    for v <- json_golden!("crypto/w3c_didkey_P256.json") do
      {:ok, priv} = Base58.decode(v["privateKeyBytesBase58"])
      kp = Crypto.from_private(:p256, priv)
      assert Crypto.did_key(kp) == v["publicDidKey"]
      assert {:ok, :p256, pub} = Crypto.parse_did_key(v["publicDidKey"])
      assert pub == kp.public
      {:ok, uncompressed} = Crypto.decompress(:p256, pub)
      assert Crypto.compress(uncompressed) == pub
    end
  end

  test "sign then verify on both curves; a flipped bit fails; other curve fails" do
    for curve <- [:k256, :p256] do
      kp = Crypto.generate(curve)
      msg = "hello, #{curve}"
      sig = Crypto.sign(kp, msg)
      assert byte_size(sig) == 64
      assert Crypto.verify(curve, kp.public, msg, sig)
      assert Crypto.verify_did_sig(Crypto.did_key(kp), msg, sig)
      <<first, rest::binary>> = sig
      refute Crypto.verify(curve, kp.public, msg, <<Bitwise.bxor(first, 1), rest::binary>>)
      refute Crypto.verify(curve, kp.public, msg <> "x", sig)
      refute Crypto.verify(curve, kp.public, msg, sig <> <<0>>)
    end
  end

  property "every produced signature is low-S (VERIFICATION §3.2)" do
    k = Crypto.generate(:k256)
    p = Crypto.generate(:p256)
    k_half = div(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141, 2)
    p_half = div(0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551, 2)

    check all(msg <- binary(min_length: 0, max_length: 64), max_runs: 40) do
      <<_::256, s::256>> = Crypto.sign(k, msg)
      assert s <= k_half
      <<_::256, s2::256>> = Crypto.sign(p, msg)
      assert s2 <= p_half
      assert Crypto.verify(:p256, p.public, msg, Crypto.sign(p, msg))
    end
  end

  test "base58btc round-trips including leading zeros" do
    for bytes <- [<<>>, <<0>>, <<0, 0, 1>>, "hello", :crypto.strong_rand_bytes(40)] do
      assert {:ok, ^bytes} = Base58.decode(Base58.encode(bytes))
    end

    assert Base58.encode(<<0, 0, 1>>) == "112"
    assert {:error, :invalid_base58} = Base58.decode("0OIl")
  end
end
