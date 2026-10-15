defmodule Aerox.Crypto.SignerTest do
  @moduledoc "DESIGN §14.2: the Remote and Kms signers against fake services; Local refused in prod."
  use ExUnit.Case, async: false
  alias Aerox.ATProto.Crypto
  alias Aerox.Crypto.Signer

  test "Local is refused in production configuration" do
    assert_raise ArgumentError, fn -> Signer.check_config!([adapter: Signer.Local], :prod) end
    assert :ok = Signer.check_config!([adapter: Signer.Remote], :prod)
  end

  test "Local is allowed in production only when the operator says so outright" do
    assert :ok = Signer.check_config!([adapter: Signer.Local, allow_in_prod: true], :prod)
    assert :ok = Signer.check_config!([adapter: Signer.Local], :staging)
    assert :ok = Signer.check_config!([adapter: Signer.Local, allow_in_prod: true], :staging)
  end

  test "Remote: pins the did:key at init, signs through the service, refuses forged signatures" do
    kp = Crypto.generate(:k256)
    bypass = Bypass.open()
    parent = self()

    Bypass.stub(bypass, "GET", "/key", fn conn ->
      assert ["Bearer s3cret"] = Plug.Conn.get_req_header(conn, "authorization")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"did_key" => Crypto.did_key(kp)}))
    end)

    Bypass.stub(bypass, "POST", "/sign", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"message" => m} = Jason.decode!(body)
      msg = Base.url_decode64!(m, padding: false)
      send(parent, {:signed, msg})
      forged? = String.contains?(msg, "forge")
      sig = if forged?, do: Crypto.sign(Crypto.generate(:k256), msg), else: Crypto.sign(kp, msg)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"signature" => Base.url_encode64(sig, padding: false)})
      )
    end)

    signer =
      Signer.from_config(
        adapter: Signer.Remote,
        url: "http://localhost:#{bypass.port}",
        secret: "s3cret"
      )

    assert Signer.did_key(signer) == Crypto.did_key(kp)
    assert {:ok, sig} = Signer.sign(signer, "hello")
    assert_receive {:signed, "hello"}
    assert Crypto.verify_did_sig(Crypto.did_key(kp), "hello", sig)
    assert {:error, :signature_does_not_verify} = Signer.sign(signer, "please forge")
  end

  test "Kms: GetPublicKey → did:key, Sign → raw low-S, SigV4-signed requests" do
    kp = Crypto.generate(:k256)
    {:ok, uncompressed} = Crypto.decompress(:k256, kp.public)
    # SPKI for secp256k1: fixed 23-byte prefix + BIT STRING with the 65-byte point
    spki =
      <<0x30, 0x56, 0x30, 0x10, 0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01, 0x06, 0x05,
        0x2B, 0x81, 0x04, 0x00, 0x0A, 0x03, 0x42, 0x00>> <> uncompressed

    bypass = Bypass.open()

    Bypass.stub(bypass, "POST", "/", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      [auth] = Plug.Conn.get_req_header(conn, "authorization")
      assert auth =~ "AWS4-HMAC-SHA256 Credential=AKIA/" and auth =~ "/eu-west-1/kms/aws4_request"
      [target] = Plug.Conn.get_req_header(conn, "x-amz-target")

      resp =
        case target do
          "TrentService.GetPublicKey" ->
            %{"PublicKey" => Base.encode64(spki), "KeySpec" => "ECC_SECG_P256K1"}

          "TrentService.Sign" ->
            %{"Message" => digest_b64, "MessageType" => "DIGEST"} = Jason.decode!(body)
            digest = Base.decode64!(digest_b64)
            der = :crypto.sign(:ecdsa, :sha256, {:digest, digest}, [kp.private, :secp256k1])
            %{"Signature" => Base.encode64(der), "SigningAlgorithm" => "ECDSA_SHA_256"}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/x-amz-json-1.1")
      |> Plug.Conn.resp(200, Jason.encode!(resp))
    end)

    signer =
      Signer.from_config(
        adapter: Signer.Kms,
        key_id: "alias/aerox",
        region: "eu-west-1",
        access_key_id: "AKIA",
        secret_access_key: "secret",
        endpoint: "http://localhost:#{bypass.port}"
      )

    assert Signer.did_key(signer) == Crypto.did_key(kp)
    assert {:ok, sig} = Signer.sign(signer, "message bytes")
    assert byte_size(sig) == 64
    assert Crypto.verify_did_sig(Crypto.did_key(kp), "message bytes", sig)
  end
end
