defmodule Aerox.ATProto.Crypto do
  @moduledoc """
  Signing and `did:key` (DESIGN §3.8). Two curves: secp256k1 (`ES256K`,
  multicodec `0xe7 0x01`) through the `ex_secp256k1` NIF, and P-256
  (`ES256`, `0x80 0x24`) through OTP `:crypto`. Keys are compressed points;
  signatures are raw `r ‖ s`, 64 bytes, over sha256 of the message.

  Two hard rules, both network-wide: signing **forces low-S**, verifying
  **rejects high-S** (and DER). Golden oracle: `interop-test-files/crypto`.
  """
  alias Aerox.ATProto.Base58

  @k256_prefix <<0xE7, 0x01>>
  @p256_prefix <<0x80, 0x24>>
  @did_key "did:key:"

  # secp256k1 and P-256 group orders, for the low-S rule.
  @k256_n 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
  @p256_n 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
  # P-256 field prime and curve b, for point decompression.
  @p256_p 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF
  @p256_b 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B

  @type curve :: :k256 | :p256
  @type alg :: String.t()

  defmodule Keypair do
    @moduledoc "A private key with its curve; `public` is the compressed point."
    @enforce_keys [:curve, :private, :public]
    defstruct [:curve, :private, :public]
    @type t :: %__MODULE__{curve: :k256 | :p256, private: <<_::256>>, public: <<_::264>>}

    defimpl Inspect do
      def inspect(%{curve: c}, _), do: "#Keypair<#{c}, redacted>"
    end
  end

  # ------------------------------------------------------------- keypair

  @spec generate(curve) :: Keypair.t()
  def generate(curve), do: from_private(curve, :crypto.strong_rand_bytes(32))

  @spec from_private(curve, <<_::256>>) :: Keypair.t()
  def from_private(:k256, priv) when byte_size(priv) == 32 do
    {:ok, pub} = ExSecp256k1.create_public_key(priv)
    %Keypair{curve: :k256, private: priv, public: compress(pub)}
  end

  def from_private(:p256, priv) when byte_size(priv) == 32 do
    {pub, ^priv} = :crypto.generate_key(:ecdh, :secp256r1, priv)
    %Keypair{curve: :p256, private: priv, public: compress(pub)}
  end

  @doc "Accepts hex (upstream's `import(hexString)`) or raw 32 bytes."
  @spec import(curve, binary) :: Keypair.t()
  def import(curve, <<hex::binary-size(64)>>) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, raw} -> from_private(curve, raw)
      :error -> from_private(curve, hex)
    end
  end

  def import(curve, raw), do: from_private(curve, raw)

  @spec jwt_alg(Keypair.t() | curve) :: alg
  def jwt_alg(%Keypair{curve: c}), do: jwt_alg(c)
  def jwt_alg(:k256), do: "ES256K"
  def jwt_alg(:p256), do: "ES256"

  @spec curve_for_alg(alg) :: {:ok, curve} | :error
  def curve_for_alg("ES256K"), do: {:ok, :k256}
  def curve_for_alg("ES256"), do: {:ok, :p256}
  def curve_for_alg(_), do: :error

  @doc "The keypair's `did:key`."
  @spec did_key(Keypair.t()) :: String.t()
  def did_key(%Keypair{curve: curve, public: public}), do: format_did_key(curve, public)

  # ---------------------------------------------------------------- sign

  @doc "Raw 64-byte low-S signature over sha256(message)."
  @spec sign(Keypair.t(), iodata) :: <<_::512>>
  def sign(%Keypair{curve: :k256, private: priv}, message) do
    {:ok, {sig, _recid}} = ExSecp256k1.sign_compact(:crypto.hash(:sha256, message), priv)
    sig
  end

  def sign(%Keypair{curve: :p256, private: priv}, message) do
    der = :crypto.sign(:ecdsa, :sha256, message, [priv, :secp256r1])
    {r, s} = der_to_rs(der)
    s = if s > div(@p256_n, 2), do: @p256_n - s, else: s
    <<r::256, s::256>>
  end

  # -------------------------------------------------------------- verify

  @doc """
  Verifies a raw 64-byte signature under a compressed public key. Anything
  that is not exactly 64 bytes (DER included) or whose S is high is invalid.
  """
  @spec verify(curve, <<_::264>>, iodata, binary) :: boolean
  def verify(curve, public, message, <<r::256, s::256>> = sig) when byte_size(public) == 33 do
    n = if curve == :k256, do: @k256_n, else: @p256_n

    cond do
      r == 0 or r >= n or s == 0 or s >= n -> false
      s > div(n, 2) -> false
      true -> do_verify(curve, public, message, sig)
    end
  end

  def verify(_curve, _public, _message, _sig), do: false

  defp do_verify(:k256, public, message, sig) do
    with {:ok, uncompressed} <- ExSecp256k1.public_key_decompress(public) do
      ExSecp256k1.verify(:crypto.hash(:sha256, message), sig, uncompressed) == :ok
    else
      _ -> false
    end
  end

  defp do_verify(:p256, public, message, <<r::256, s::256>>) do
    case decompress_p256(public) do
      {:ok, uncompressed} ->
        :crypto.verify(:ecdsa, :sha256, message, rs_to_der(r, s), [uncompressed, :secp256r1])

      :error ->
        false
    end
  end

  @doc "Verifies against a `did:key`; the curve comes from the key's multicodec prefix."
  @spec verify_did_sig(String.t(), iodata, binary) :: boolean
  def verify_did_sig(did_key, message, sig) do
    case parse_did_key(did_key) do
      {:ok, curve, public} -> verify(curve, public, message, sig)
      _ -> false
    end
  end

  # ------------------------------------------------------------- did:key

  @doc "`did:key:z…` for a compressed public key."
  @spec format_did_key(curve, <<_::264>>) :: String.t()
  def format_did_key(curve, public), do: @did_key <> format_multikey(curve, public)

  @doc "The multikey form (`z` + base58btc of prefix ‖ compressed key), as used in `publicKeyMultibase`."
  @spec format_multikey(curve, <<_::264>>) :: String.t()
  def format_multikey(curve, public) when byte_size(public) == 33,
    do: "z" <> Base58.encode(prefix(curve) <> public)

  @spec parse_did_key(term) :: {:ok, curve, <<_::264>>} | {:error, term}
  def parse_did_key(@did_key <> multikey), do: parse_multikey(multikey)
  def parse_did_key(_), do: {:error, :not_a_did_key}

  @spec parse_multikey(term) :: {:ok, curve, <<_::264>>} | {:error, term}
  def parse_multikey("z" <> b58) do
    with {:ok, bytes} <- Base58.decode(b58) do
      case bytes do
        <<@k256_prefix, key::binary-size(33)>> -> {:ok, :k256, key}
        <<@p256_prefix, key::binary-size(33)>> -> {:ok, :p256, key}
        _ -> {:error, :unsupported_key_type}
      end
    end
  end

  def parse_multikey(_), do: {:error, :unsupported_multibase}

  @doc """
  A DID document verification method → `did:key`. `Multikey` carries the
  multicodec prefix; the two legacy 2019 types carry a bare compressed key
  and the curve comes from the type (upstream `getDidKeyFromMultibase`).
  """
  @spec did_key_from_verification_method(String.t() | nil, String.t()) ::
          {:ok, String.t()} | {:error, term}
  def did_key_from_verification_method("Multikey", multibase) do
    with {:ok, curve, key} <- parse_multikey(multibase), do: {:ok, format_did_key(curve, key)}
  end

  def did_key_from_verification_method("EcdsaSecp256r1VerificationKey2019", multibase),
    do: legacy_did_key(:p256, multibase)

  def did_key_from_verification_method("EcdsaSecp256k1VerificationKey2019", multibase),
    do: legacy_did_key(:k256, multibase)

  def did_key_from_verification_method(type, _),
    do: {:error, {:unsupported_verification_method, type}}

  defp legacy_did_key(curve, "z" <> b58) do
    with {:ok, bytes} <- Base58.decode(b58) do
      case bytes do
        <<p, _::binary-size(32)>> when p in [0x02, 0x03] -> {:ok, format_did_key(curve, bytes)}
        <<0x04, _::binary-size(64)>> -> {:ok, format_did_key(curve, compress(bytes))}
        _ -> {:error, :invalid_key_bytes}
      end
    end
  end

  defp legacy_did_key(_, _), do: {:error, :unsupported_multibase}

  @doc "The JWT `alg` a did:key signs with."
  @spec did_key_alg(String.t()) :: {:ok, alg} | {:error, term}
  def did_key_alg(did_key) do
    with {:ok, curve, _} <- parse_did_key(did_key), do: {:ok, jwt_alg(curve)}
  end

  defp prefix(:k256), do: @k256_prefix
  defp prefix(:p256), do: @p256_prefix

  # --------------------------------------------------------------- points

  @doc "Compressed form of an uncompressed (65-byte) point; compressed input passes through."
  @spec compress(binary) :: <<_::264>>
  def compress(<<0x04, x::binary-size(32), y::256>>),
    do: <<if(rem(y, 2) == 0, do: 0x02, else: 0x03), x::binary>>

  def compress(<<p, _::binary-size(32)>> = compressed) when p in [0x02, 0x03], do: compressed

  @doc "Uncompressed (65-byte) form of a compressed point."
  @spec decompress(curve, <<_::264>>) :: {:ok, <<_::520>>} | :error
  def decompress(:k256, public) do
    case ExSecp256k1.public_key_decompress(public) do
      {:ok, pub} -> {:ok, pub}
      _ -> :error
    end
  end

  def decompress(:p256, public), do: decompress_p256(public)

  defp decompress_p256(<<parity, x::256>>) when parity in [0x02, 0x03] and x < @p256_p do
    # y² = x³ − 3x + b; p ≡ 3 (mod 4) so sqrt(a) = a^((p+1)/4)
    x3 = :binary.decode_unsigned(:crypto.mod_pow(x, 3, @p256_p))
    rhs = Integer.mod(x3 - 3 * x + @p256_b, @p256_p)
    y = :crypto.mod_pow(rhs, div(@p256_p + 1, 4), @p256_p) |> :binary.decode_unsigned()

    if rem(y * y, @p256_p) == rhs do
      y = if rem(y, 2) == parity - 2, do: y, else: @p256_p - y
      {:ok, <<0x04, x::256, y::256>>}
    else
      :error
    end
  end

  defp decompress_p256(_), do: :error

  # ------------------------------------------------------------- DER/raw

  defp der_to_rs(<<0x30, _len, 0x02, rlen, rest::binary>>) do
    <<r::binary-size(^rlen), 0x02, slen, s::binary-size(slen)>> = rest
    {:binary.decode_unsigned(r), :binary.decode_unsigned(s)}
  end

  defp rs_to_der(r, s) do
    rb = der_int(r)
    sb = der_int(s)
    body = <<0x02, byte_size(rb), rb::binary, 0x02, byte_size(sb), sb::binary>>
    <<0x30, byte_size(body), body::binary>>
  end

  defp der_int(i) do
    bin = :binary.encode_unsigned(i)
    if match?(<<b, _::binary>> when b >= 0x80, bin), do: <<0, bin::binary>>, else: bin
  end
end
