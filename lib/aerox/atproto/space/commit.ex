defmodule Aerox.ATProto.Space.Commit do
  @moduledoc """
  `com.atproto.space.defs#signedCommit` (DESIGN §12.2, upstream `space/commit.ts`):
  `hash` = LtHash digest, `ikm` = 32 random bytes, `mac` =
  HMAC-SHA256(HKDF-SHA256(ikm, info = ctx), hash) where ctx binds the space
  DID, type, key, user DID, rev and scope under the `atproto-space-v1`
  domain, and `sig` = the user's signing key over `ikm` (not over the hash —
  a rebroadcast proves nothing, the commit is deniable).
  Golden: `test/golden/space/commit.json`.
  """
  alias Aerox.ATProto.Crypto

  @domain "atproto-space-v1"

  @type context :: %{
          space_did: String.t(),
          space_type: String.t(),
          space_key: String.t(),
          user_did: String.t(),
          rev: String.t(),
          scope: String.t()
        }
  @type t :: %{hash: binary, ikm: binary, mac: binary, sig: binary, rev: String.t()}

  @doc "The HKDF info bytes for a commit context (upstream encodeCommitInfo)."
  @spec info(context) :: binary
  def info(ctx) do
    fields = [ctx.space_did, ctx.space_type, ctx.space_key, ctx.user_did, ctx.rev, ctx.scope]
    Enum.reduce(fields, @domain, fn f, acc -> acc <> <<byte_size(f)::16-big, f::binary>> end)
  end

  @doc "HKDF-SHA256 (RFC 5869) with an empty salt, one 32-byte block."
  @spec derive_key(binary, binary) :: <<_::256>>
  def derive_key(ikm, info) do
    prk = :crypto.mac(:hmac, :sha256, <<0::256>>, ikm)
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
  end

  @spec mac(binary, binary, context) :: <<_::256>>
  def mac(ikm, hash, ctx), do: :crypto.mac(:hmac, :sha256, derive_key(ikm, info(ctx)), hash)

  @doc "Sign a commit over the current LtHash state (`hash` is its digest)."
  @spec create(binary, context, Crypto.Keypair.t()) :: t
  def create(hash, ctx, %Crypto.Keypair{} = keypair) do
    ikm = :crypto.strong_rand_bytes(32)

    %{
      hash: hash,
      ikm: ikm,
      mac: mac(ikm, hash, ctx),
      sig: Crypto.sign(keypair, ikm),
      rev: ctx.rev
    }
  end

  @doc "The MAC binds the hash to this context (upstream verifyCommit)."
  @spec verify_mac(t, context) :: boolean
  def verify_mac(%{ikm: ikm, hash: hash, mac: mac}, ctx),
    do: Plug.Crypto.secure_compare(mac(ikm, hash, ctx), mac)

  @doc "The signature over `ikm` verifies under the user's `did:key`."
  @spec verify_sig(t, String.t()) :: boolean
  def verify_sig(%{ikm: ikm, sig: sig}, did_key), do: Crypto.verify_did_sig(did_key, ikm, sig)

  @doc "The lexicon's JSON/CBOR shape (bytes wrapped)."
  def to_lex(%{hash: h, ikm: i, mac: m, sig: s, rev: rev}) do
    b = &Aerox.ATProto.Bytes.new/1
    %{"hash" => b.(h), "ikm" => b.(i), "mac" => b.(m), "sig" => b.(s), "rev" => rev}
  end

  def from_lex(%{"hash" => h, "ikm" => i, "mac" => m, "sig" => s, "rev" => rev}) do
    u = fn
      %Aerox.ATProto.Bytes{data: d} -> d
      %{"$bytes" => b64} -> Base.decode64!(b64, padding: false)
      bin when is_binary(bin) -> bin
    end

    %{hash: u.(h), ikm: u.(i), mac: u.(m), sig: u.(s), rev: rev}
  end
end
