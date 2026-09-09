defmodule Aerox.Interop.BundleTest do
  @moduledoc """
  The bundle format and its encryption on their own (DESIGN §13.0, VERIFICATION §8):
  chunked AES-GCM fails on truncation / reordering / wrong key, the JWE key
  wrap opens only for the intended recipient, manifest tampering is caught,
  unknown major versions are refused and unknown files tolerated.
  """
  use ExUnit.Case, async: true
  alias Aerox.ATProto.{CAR, CID, DagCBOR}
  alias Aerox.ATProto.Crypto, as: KCrypto
  alias Aerox.ATProto.Repo, as: KRepo
  alias Aerox.ATProto.Blockstore.Memory
  alias Aerox.Interop.Bundle
  alias Aerox.Interop.Bundle.Crypto

  @moduletag :tmp_dir

  # ------------------------------------------------------------ crypto

  describe "chunked AES-256-GCM" do
    test "round-trips any chunking, including empty and exact multiples" do
      key = Crypto.generate_content_key()

      for size <- [0, 1, 99, 100, 101, 250, 1000] do
        plain = :crypto.strong_rand_bytes(size)
        chunks = for <<c::binary-size(7) <- plain>>, do: c
        tail = binary_part(plain, byte_size(plain) - rem(size, 7), rem(size, 7))

        enc =
          key
          |> Crypto.encrypt_stream("f", chunks ++ [tail], 100)
          |> Enum.map(&IO.iodata_to_binary/1)

        bytes = IO.iodata_to_binary(enc)
        rechunked = for <<c::binary-size(13) <- bytes>>, do: c

        rest =
          binary_part(
            bytes,
            byte_size(bytes) - rem(byte_size(bytes), 13),
            rem(byte_size(bytes), 13)
          )

        out =
          key
          |> Crypto.decrypt_stream("f", rechunked ++ [rest])
          |> Enum.to_list()
          |> IO.iodata_to_binary()

        assert out == plain, "size #{size}"
      end
    end

    test "truncation, reordering, splicing, a flipped bit and the wrong key all fail" do
      key = Crypto.generate_content_key()
      plain = :crypto.strong_rand_bytes(350)

      bytes =
        key
        |> Crypto.encrypt_stream("repo.car", [plain], 100)
        |> Enum.to_list()
        |> IO.iodata_to_binary()

      dec = fn k, name, b ->
        k |> Crypto.decrypt_stream(name, [b]) |> Enum.to_list() |> IO.iodata_to_binary()
      end

      assert dec.(key, "repo.car", bytes) == plain

      # chunk = 4 + 1 + 100 + 16 = 121 bytes after the 8-byte header
      chunk1 = binary_part(bytes, 8, 121)
      chunk2 = binary_part(bytes, 8 + 121, 121)
      rest = binary_part(bytes, 8 + 242, byte_size(bytes) - 8 - 242)
      header = binary_part(bytes, 0, 8)

      assert_raise Crypto.Error, ~r/truncated/, fn ->
        dec.(key, "repo.car", header <> chunk1 <> chunk2)
      end

      assert_raise Crypto.Error, ~r/authentication_failed/, fn ->
        dec.(key, "repo.car", header <> chunk2 <> chunk1 <> rest)
      end

      assert_raise Crypto.Error, ~r/authentication_failed/, fn ->
        dec.(key, "repo.car", header <> chunk1 <> rest)
      end

      assert_raise Crypto.Error, ~r/authentication_failed/, fn ->
        dec.(key, "account.json", bytes)
      end

      assert_raise Crypto.Error, ~r/authentication_failed/, fn ->
        dec.(Crypto.generate_content_key(), "repo.car", bytes)
      end

      assert_raise Crypto.Error, ~r/trailing_data/, fn -> dec.(key, "repo.car", bytes <> "x") end

      <<pre::binary-size(50), b, post::binary>> = bytes

      assert_raise Crypto.Error, fn ->
        dec.(key, "repo.car", <<pre::binary, Bitwise.bxor(b, 1), post::binary>>)
      end

      assert_raise Crypto.Error, ~r/not_encrypted/, fn -> dec.(key, "repo.car", plain) end
    end
  end

  describe "content key wrap" do
    test "P-256, X25519 and passphrase recipients; only the right secret unwraps" do
      ck = Crypto.generate_content_key()
      p256 = JOSE.JWK.generate_key({:ec, "P-256"})
      x = JOSE.JWK.generate_key({:okp, :X25519})

      entries =
        Crypto.wrap_key(ck, [
          {:jwk, JOSE.JWK.to_public(p256)},
          {:jwk, JOSE.JWK.to_public(x)},
          {:passphrase, "open sesame"}
        ])

      assert length(entries) == 3
      assert Enum.map(entries, & &1["type"]) == ["jwk", "jwk", "passphrase"]

      assert {:ok, ^ck} = Crypto.unwrap_key(entries, {:jwk, p256})
      assert {:ok, ^ck} = Crypto.unwrap_key(entries, {:jwk, x})
      assert {:ok, ^ck} = Crypto.unwrap_key(entries, {:passphrase, "open sesame"})
      assert :error = Crypto.unwrap_key(entries, {:jwk, JOSE.JWK.generate_key({:ec, "P-256"})})
      assert :error = Crypto.unwrap_key(entries, {:jwk, JOSE.JWK.generate_key({:okp, :X25519})})
      assert :error = Crypto.unwrap_key(entries, {:passphrase, "open sesame!"})

      # the PBES2 header records the iteration count we asked for
      [_, _, %{"jwe" => jwe}] = entries

      header =
        jwe |> String.split(".") |> hd() |> Base.url_decode64!(padding: false) |> Jason.decode!()

      assert %{"alg" => "PBES2-HS512+A256KW", "p2c" => 210_000} = header
    end

    test "parse_jwk accepts PEM and JWK, literal or file", %{tmp_dir: dir} do
      sk = JOSE.JWK.generate_key({:ec, "P-256"})
      {_, pem} = JOSE.JWK.to_pem(JOSE.JWK.to_public(sk))
      {_, map} = JOSE.JWK.to_map(sk)
      path = Path.join(dir, "k.pem")
      File.write!(path, pem)
      assert {:ok, %JOSE.JWK{}} = Crypto.parse_jwk(pem)
      assert {:ok, %JOSE.JWK{}} = Crypto.parse_jwk(path)
      assert {:ok, %JOSE.JWK{}} = Crypto.parse_jwk(Jason.encode!(map))
      assert {:error, _} = Crypto.parse_jwk("nope")
    end
  end

  describe "manifest JWS" do
    test "signs with the instance signer and verifies against the did:key in the header" do
      signer = Aerox.PDS.Config.signer()
      assert {:ok, jws} = Crypto.sign(~s({"a":1}), signer)
      assert {:ok, ~s({"a":1}), did_key} = Crypto.verify(jws)
      assert did_key == Aerox.Crypto.Signer.did_key(signer)
      [h, p, s] = String.split(jws, ".")

      assert {:error, :bad_signature} =
               Crypto.verify(
                 h <> "." <> Base.url_encode64(~s({"a":2}), padding: false) <> "." <> s
               )

      assert {:error, _} = Crypto.verify(h <> "." <> p)
    end
  end

  # ------------------------------------------------------------ format

  defp synthetic_contents do
    did = "did:plc:bundletest#{System.unique_integer([:positive])}"
    keypair = KCrypto.generate(:k256)
    {:ok, commit} = KRepo.format_init_commit(Memory.new(), did, keypair, [], "3aaaaaaaaaaaa")
    car = CAR.encode(commit.cid, Map.to_list(commit.new_blocks))
    blob = :crypto.strong_rand_bytes(3000)

    %{
      did: did,
      handle: "bundle.test",
      source: %{"impl" => "test", "version" => "0", "host" => "src.example"},
      account: %{
        "did" => did,
        "handle" => "bundle.test",
        "email" => "b@example.com",
        "password_scrypt" => "s:h"
      },
      signing_key: keypair.private,
      repo_car: car,
      state: %{"records" => %{}, "blobs" => %{}},
      counts: %{records: 0, blocks: map_size(commit.new_blocks)},
      blobs: [{CID.to_string(CID.for_raw(blob)), blob}],
      seq:
        {Bundle.encode_seq([
           %{
             seq: 7,
             did: did,
             event_type: "identity",
             event: DagCBOR.encode(%{"did" => did}),
             invalidated: false,
             sequenced_at: DateTime.utc_now()
           }
         ]), 1}
    }
  end

  test "plaintext is refused without the flag; written and read back with it", %{tmp_dir: dir} do
    c = synthetic_contents()
    assert {:error, :refusing_plaintext_bundle} = Bundle.write(Path.join(dir, "a"), c)
    assert {:ok, manifest} = Bundle.write(Path.join(dir, "a"), c, insecure_plaintext: true)
    assert manifest["bundle_version"] == 1 and manifest["encryption"] == nil

    assert manifest["counts"] == %{
             "records" => 0,
             "blocks" => 2,
             "blobs" => 1,
             "quarantine" => 0,
             "seq_events" => 1
           }

    assert {:ok, b} = Bundle.read(Path.join(dir, "a"))
    refute Bundle.encrypted?(b)
    assert :ok = Bundle.verify_hashes(b)
    assert {:ok, car} = Bundle.read_file(b, "repo.car")
    assert car == c.repo_car
    assert File.read!(Path.join([dir, "a", "repo.car"])) == c.repo_car
    assert {:ok, [%{seq: 7, event_type: "identity"}]} = Bundle.seq_rows(b)

    assert {:error, {:directory_not_empty, _}} =
             Bundle.write(Path.join(dir, "a"), c, insecure_plaintext: true)
  end

  test "encrypted bundle: files are opaque, decrypt only with the right key or passphrase", %{
    tmp_dir: dir
  } do
    c = synthetic_contents()
    sk = JOSE.JWK.generate_key({:ec, "P-256"})
    out = Path.join(dir, "e")

    assert {:ok, manifest} =
             Bundle.write(out, c,
               recipients: [{:jwk, JOSE.JWK.to_public(sk)}, {:passphrase, "pw"}],
               chunk_size: 64
             )

    assert %{"scheme" => "aerox-bundle-v1", "chunk_size" => 64, "recipients" => [_, _]} =
             manifest["encryption"]

    refute File.read!(Path.join(out, "repo.car")) == c.repo_car
    assert <<"AXB1", 64::32, _::binary>> = File.read!(Path.join(out, "signing.key"))
    refute File.read!(Path.join(out, "account.json")) =~ "password_scrypt"

    assert {:error, :bundle_is_encrypted} = Bundle.read(out)

    assert {:error, :cannot_unwrap_content_key} =
             Bundle.read(out, secret: {:jwk, JOSE.JWK.generate_key({:ec, "P-256"})})

    assert {:error, :cannot_unwrap_content_key} = Bundle.read(out, secret: {:passphrase, "pw2"})

    for secret <- [{:jwk, sk}, {:passphrase, "pw"}] do
      assert {:ok, b} = Bundle.read(out, secret: secret)
      assert Bundle.encrypted?(b)
      assert :ok = Bundle.verify_hashes(b)
      assert {:ok, car} = Bundle.read_file(b, "repo.car")
      assert car == c.repo_car
      assert {:ok, key} = Bundle.read_file(b, "signing.key")
      assert key == c.signing_key
    end
  end

  test "manifest tampering is detected: payload edits break the JWS, file edits break the hashes",
       %{tmp_dir: dir} do
    c = synthetic_contents()
    out = Path.join(dir, "t")
    {:ok, _} = Bundle.write(out, c, insecure_plaintext: true)
    manifest_path = Path.join(out, "manifest.json")
    original = File.read!(manifest_path)
    raw = Jason.decode!(original)

    # 1. edit the JWS payload (a hash) → signature fails
    [h, p, s] = String.split(raw["signature"]["jws"], ".")
    payload = p |> Base.url_decode64!(padding: false) |> Jason.decode!()
    forged = put_in(payload, ["hashes", "repo_car"], String.duplicate("0", 64))
    forged_jws = h <> "." <> Base.url_encode64(Jason.encode!(forged), padding: false) <> "." <> s
    File.write!(manifest_path, Jason.encode!(put_in(raw, ["signature", "jws"], forged_jws)))
    assert {:error, :bad_signature} = Bundle.read(out)

    # 2. edit a readable field only → ignored (the payload is authoritative)
    File.write!(manifest_path, Jason.encode!(put_in(raw, ["hashes", "repo_car"], "ffff")))
    assert {:ok, b} = Bundle.read(out)
    assert b.manifest["hashes"]["repo_car"] == raw["hashes"]["repo_car"]

    # 3. edit a file → its hash no longer matches
    File.write!(manifest_path, original)
    File.write!(Path.join(out, "account.json"), ~s({"did":"x"}))
    assert {:ok, b} = Bundle.read(out)
    assert {:error, [{:hash_mismatch, "account.json", _, _}]} = Bundle.verify_hashes(b)

    # 4. a blob whose bytes no longer hash to its CID
    File.write!(Path.join(out, "account.json"), Jason.encode!(c.account, pretty: true))
    [cid] = raw["hashes"]["blobs"]
    File.write!(Path.join([out, "blobs", cid]), "not the blob")
    assert {:error, [{:hash_mismatch, "blobs/" <> ^cid}]} = Bundle.verify_hashes(b)

    # 5. unsigned or unexpected signer
    File.write!(manifest_path, Jason.encode!(Map.delete(raw, "signature")))
    assert {:error, :unsigned_manifest} = Bundle.read(out)
    File.write!(manifest_path, original)

    assert {:error, {:unexpected_signer, _}} =
             Bundle.read(out,
               expect_signer: "did:key:zQ3shZc2QzApp2oymGvQbzP8eKheVshBHbU4ZYjeXqwSKEn6N"
             )
  end

  test "unknown major version refused, unknown files tolerated", %{tmp_dir: dir} do
    c = synthetic_contents()
    out = Path.join(dir, "v")
    {:ok, _} = Bundle.write(out, c, insecure_plaintext: true)
    File.write!(Path.join(out, "spaces.notyet"), "future")
    File.mkdir_p!(Path.join(out, "spaces"))
    assert {:ok, b} = Bundle.read(out)
    assert :ok = Bundle.verify_hashes(b)

    # re-sign a version-2 manifest with the real signer: only the version check can refuse it
    raw = Jason.decode!(File.read!(Path.join(out, "manifest.json")))
    payload = Map.put(Map.delete(raw, "signature"), "bundle_version", 2)
    {:ok, jws} = Crypto.sign(Jason.encode!(payload), Aerox.PDS.Config.signer())

    File.write!(
      Path.join(out, "manifest.json"),
      Jason.encode!(Map.put(payload, "signature", %{"jws" => jws}))
    )

    assert {:error, {:unsupported_bundle_version, 2}} = Bundle.read(out)
  end

  test "discover finds a single bundle or a directory of them", %{tmp_dir: dir} do
    c1 = synthetic_contents()
    c2 = synthetic_contents()
    {:ok, _} = Bundle.write(Path.join(dir, c1.did), c1, insecure_plaintext: true)
    {:ok, _} = Bundle.write(Path.join(dir, c2.did), c2, insecure_plaintext: true)
    File.mkdir_p!(Path.join(dir, "not-a-bundle"))
    assert Bundle.discover(dir) == Enum.sort([Path.join(dir, c1.did), Path.join(dir, c2.did)])
    assert Bundle.discover(Path.join(dir, c1.did)) == [Path.join(dir, c1.did)]
    assert Bundle.discover(Path.join(dir, "missing")) == []
  end
end
