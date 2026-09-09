defmodule Aerox.ATProto.Space.SignedCommit do
  @moduledoc """
  `com.atproto.space.defs#signedCommit` as the **published Spaces alpha**
  emits it (`@atproto/space@0.0.0-spaces-alpha-20260818163953`, the package
  the `bulletin` client pins — DESIGN §12.1's oracle; `repo-commit.ts`):

      ctx = "atproto-space-v1"
          || uint16be(len(space))  || space      (the space URI)
          || uint16be(len(author)) || author     (the writer's DID)
          || uint16be(len(rev))    || rev
          || uint16be(len(ikm))    || ikm
      mac = HMAC-SHA256(HKDF-Expand-SHA256(ikm, info = ctx, 32), hash)
      sig = sign(author's #atproto key, ctx)

  `ver` is 1. The signature covers only the context (with the fresh `ikm`),
  never the digest: a leaked commit proves nothing about the repo's contents,
  while the MAC binds the digest to this context for anyone holding the
  commit. `Aerox.ATProto.Space.Commit` is the earlier `permissioned-data`
  branch shape (space parts + scope, HKDF extract, sig over ikm); this is
  the one on the wire. Golden: `test/golden/space/alpha.json`.
  """
  alias Aerox.ATProto.{Bytes, Crypto}

  @domain "atproto-space-v1"
  @version 1

  @type context :: %{space: String.t(), author: String.t(), rev: String.t()}
  @type t :: %{
          ver: pos_integer,
          hash: binary,
          ikm: binary,
          mac: binary,
          sig: binary,
          rev: String.t()
        }

  def version, do: @version

  @doc "Upstream `encodeCommitCtx`."
  @spec ctx_bytes(context, binary) :: binary
  def ctx_bytes(%{space: space, author: author, rev: rev}, ikm) do
    Enum.reduce([space, author, rev, ikm], @domain, fn f, acc ->
      if byte_size(f) > 0xFFFF, do: raise(ArgumentError, "commit ctx field exceeds uint16 length")
      acc <> <<byte_size(f)::16-big, f::binary>>
    end)
  end

  @doc "Upstream `hkdfSha256(ikm, info)`: HKDF-Expand only (the ikm is the PRK), one 32-byte block."
  @spec derive_key(binary, binary) :: <<_::256>>
  def derive_key(ikm, info), do: :crypto.mac(:hmac, :sha256, ikm, info <> <<1>>)

  @spec mac(binary, binary, binary) :: <<_::256>>
  def mac(ikm, ctx_bytes, hash), do: :crypto.mac(:hmac, :sha256, derive_key(ikm, ctx_bytes), hash)

  @doc "Upstream `RepoCommit.sign`: a commit over `hash` (the LtHash digest) in `ctx`."
  @spec create(binary, context, Crypto.Keypair.t(), keyword) :: t
  def create(hash, ctx, %Crypto.Keypair{} = keypair, opts \\ []) do
    ikm = Keyword.get_lazy(opts, :ikm, fn -> :crypto.strong_rand_bytes(32) end)
    ctx_bytes = ctx_bytes(ctx, ikm)

    %{
      ver: @version,
      hash: hash,
      ikm: ikm,
      mac: mac(ikm, ctx_bytes, hash),
      sig: Crypto.sign(keypair, ctx_bytes),
      rev: ctx.rev
    }
  end

  @doc "The MAC binds `hash` to this context (integrity, for a holder of the commit)."
  @spec verify_mac(t, context) :: boolean
  def verify_mac(%{ver: @version, ikm: ikm, hash: hash, mac: mac, rev: rev}, %{rev: rev} = ctx),
    do: Plug.Crypto.secure_compare(mac(ikm, ctx_bytes(ctx, ikm), hash), mac)

  def verify_mac(_, _), do: false

  @doc "The signature over the context verifies under the author's `did:key` (authenticity)."
  @spec verify_sig(t, context, String.t()) :: boolean
  def verify_sig(%{ver: @version, ikm: ikm, sig: sig, rev: rev}, %{rev: rev} = ctx, did_key),
    do: Crypto.verify_did_sig(did_key, ctx_bytes(ctx, ikm), sig)

  def verify_sig(_, _, _), do: false

  @doc "Upstream `verifyCommit`: version, rev, MAC and signature."
  @spec verify(t, context, String.t()) :: boolean
  def verify(commit, ctx, did_key),
    do: verify_mac(commit, ctx) and verify_sig(commit, ctx, did_key)

  @doc "The lexicon's JSON/CBOR shape (bytes wrapped)."
  def to_lex(%{ver: ver, hash: h, ikm: i, mac: m, sig: s, rev: rev}),
    do: %{
      "ver" => ver,
      "hash" => Bytes.new(h),
      "ikm" => Bytes.new(i),
      "mac" => Bytes.new(m),
      "sig" => Bytes.new(s),
      "rev" => rev
    }

  def from_lex(%{"hash" => h, "ikm" => i, "mac" => m, "sig" => s, "rev" => rev} = lex) do
    u = fn
      %Bytes{data: d} -> d
      %{"$bytes" => b64} -> Base.decode64!(b64, padding: false)
      bin when is_binary(bin) -> bin
    end

    %{
      ver: Map.get(lex, "ver", @version),
      hash: u.(h),
      ikm: u.(i),
      mac: u.(m),
      sig: u.(s),
      rev: rev
    }
  end
end
