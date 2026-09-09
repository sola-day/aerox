defmodule Aerox.Interop.Bundle.Crypto do
  @moduledoc """
  Bundle encryption, DESIGN §13.0 **Option A** (decided 2026-09-09, see
  `docs/BUNDLE.md`): standard primitives from libraries the release already
  carries, no external binary.

    * One random 256-bit **content key** per bundle.
    * The content key is wrapped as a compact **JWE** per recipient with
      `jose`: `ECDH-ES+A256KW` to a P-256 or X25519 public key
      (provider-to-provider transfer) and/or `PBES2-HS512+A256KW` under a
      passphrase (operator backups). jose 1.11 cannot mint the ephemeral key
      itself (`derive_key/1` is missing), so the ephemeral pair is generated
      here and handed in; jose's default PBES2 iteration cap (10 000) is
      raised at runtime to allow the 210 000 iterations used (OWASP 2023 minimum for PBKDF2-HMAC-SHA512; jose's PBKDF2 is pure Erlang, ~3 s per wrap).
    * Each file body is encrypted in **chunks with AES-256-GCM** under a
      per-file subkey `HMAC-SHA256(content_key, "aerox-bundle-v1/file\\0" ‖ path)`.
      The nonce is the chunk index; the AAD binds the file path, the chunk
      index and a last-chunk flag, so a truncated, reordered or spliced file
      fails authentication. Files stream in both directions.
    * The manifest is signed as a compact **JWS** (`ES256K` or `ES256`) with
      the exporting instance's `Aerox.Crypto.Signer`, so a receiver can
      check origin before decrypting anything.

  ## Encrypted file layout

      "AXB1" ‖ chunk_size:u32 ‖ chunk*
      chunk = ct_len:u32 ‖ last:u8 ‖ ciphertext ‖ tag:16

  The plaintext size of every chunk except the last is `chunk_size`; an
  empty file is one empty last chunk.
  """

  alias Aerox.ATProto.Crypto, as: KCrypto

  defmodule Error do
    defexception [:message, :reason]
  end

  @magic "AXB1"
  @default_chunk 1_048_576
  @tag_len 16
  @pbes2_iterations 210_000
  @key_wrap_alg "ECDH-ES+A256KW"
  @pass_wrap_alg "PBES2-HS512+A256KW"

  @type recipient :: {:jwk, JOSE.JWK.t()} | {:passphrase, String.t()}

  @doc "The default plaintext chunk size (1 MiB)."
  def default_chunk_size, do: @default_chunk

  @doc "A fresh 256-bit content key."
  @spec generate_content_key() :: <<_::256>>
  def generate_content_key, do: :crypto.strong_rand_bytes(32)

  # ------------------------------------------------------------ file bodies

  @doc "Per-file subkey (never the content key itself on the wire)."
  @spec file_key(<<_::256>>, String.t()) :: <<_::256>>
  def file_key(content_key, path) when byte_size(content_key) == 32,
    do: :crypto.mac(:hmac, :sha256, content_key, "aerox-bundle-v1/file\0" <> path)

  @doc "Lazily encrypts an enumerable of binary chunks into the layout above."
  @spec encrypt_stream(<<_::256>>, String.t(), Enumerable.t(), pos_integer) :: Enumerable.t()
  def encrypt_stream(content_key, path, chunks, chunk_size \\ @default_chunk) do
    key = file_key(content_key, path)

    body =
      chunks
      |> rechunk(chunk_size)
      |> Stream.with_index()
      |> Stream.map(fn {{plain, last?}, index} ->
        {ct, tag} =
          :crypto.crypto_one_time_aead(
            :aes_256_gcm,
            key,
            nonce(index),
            plain,
            aad(path, index, last?),
            @tag_len,
            true
          )

        [<<byte_size(ct)::32, flag(last?)>>, ct, tag]
      end)

    Stream.concat([[@magic, <<chunk_size::32>>]], body)
  end

  @doc """
  Lazily decrypts an enumerable of binary chunks (any chunking). Raises
  `Aerox.Interop.Bundle.Crypto.Error` on a wrong key, a modified, truncated,
  reordered or spliced file.
  """
  @spec decrypt_stream(<<_::256>>, String.t(), Enumerable.t()) :: Enumerable.t()
  def decrypt_stream(content_key, path, chunks) do
    key = file_key(content_key, path)

    Stream.transform(
      chunks,
      fn -> %{buf: <<>>, index: 0, chunk_size: nil, done: false} end,
      fn chunk, st -> drain(%{st | buf: st.buf <> chunk}, key, path, []) end,
      fn st ->
        cond do
          st.chunk_size == nil -> fail(path, :missing_header)
          not st.done -> fail(path, :truncated)
          st.buf != <<>> -> fail(path, :trailing_data)
          true -> {[], st}
        end
      end,
      fn _ -> :ok end
    )
  end

  # Consume as many complete records from the buffer as possible.
  defp drain(%{chunk_size: nil} = st, key, path, acc) do
    case st.buf do
      <<@magic, chunk_size::32, rest::binary>> when chunk_size > 0 ->
        drain(%{st | buf: rest, chunk_size: chunk_size}, key, path, acc)

      <<@magic, _::32, _::binary>> ->
        fail(path, :bad_chunk_size)

      <<_::binary-size(8), _::binary>> ->
        fail(path, :not_encrypted_bundle_file)

      _ ->
        {Enum.reverse(acc), st}
    end
  end

  defp drain(%{done: true, buf: buf} = st, _key, path, acc) do
    if buf == <<>>, do: {Enum.reverse(acc), st}, else: fail(path, :trailing_data)
  end

  defp drain(st, key, path, acc) do
    case st.buf do
      <<len::32, flag, ct::binary-size(len), tag::binary-size(@tag_len), rest::binary>> ->
        last? = flag == 1
        if flag not in [0, 1], do: fail(path, :bad_chunk_flag)

        case :crypto.crypto_one_time_aead(
               :aes_256_gcm,
               key,
               nonce(st.index),
               ct,
               aad(path, st.index, last?),
               tag,
               false
             ) do
          :error ->
            fail(path, {:authentication_failed, st.index})

          plain ->
            if not last? and byte_size(plain) != st.chunk_size,
              do: fail(path, {:short_chunk, st.index})

            drain(%{st | buf: rest, index: st.index + 1, done: last?}, key, path, [plain | acc])
        end

      _ ->
        {Enum.reverse(acc), st}
    end
  end

  defp fail(path, reason),
    do: raise(Error, message: "#{path}: #{inspect(reason)}", reason: reason)

  defp nonce(index), do: <<0::64, index::32>>
  defp flag(true), do: 1
  defp flag(false), do: 0
  defp aad(path, index, last?), do: <<path::binary, 0, index::32, flag(last?)>>

  # Exactly chunk_size-byte pieces, then a (possibly empty) final piece flagged last.
  defp rechunk(chunks, size) do
    Stream.transform(
      chunks,
      fn -> <<>> end,
      fn chunk, buf -> split_full(buf <> chunk, size, []) end,
      fn buf -> {[{buf, true}], <<>>} end,
      fn _ -> :ok end
    )
  end

  defp split_full(buf, size, acc) when byte_size(buf) >= size do
    <<piece::binary-size(^size), rest::binary>> = buf
    split_full(rest, size, [{piece, false} | acc])
  end

  defp split_full(buf, _size, acc), do: {Enum.reverse(acc), buf}

  # ------------------------------------------------------------- key wrap

  @doc "Wraps the content key once per recipient; returns manifest-ready entries."
  @spec wrap_key(<<_::256>>, [recipient]) :: [map]
  def wrap_key(content_key, recipients) when recipients != [] do
    Enum.map(recipients, fn
      {:jwk, %JOSE.JWK{} = jwk} ->
        ephemeral = ephemeral_for(jwk)

        {_, jwe} =
          JOSE.JWE.block_encrypt({JOSE.JWK.to_public(jwk), ephemeral}, content_key, %{
            "alg" => @key_wrap_alg,
            "enc" => "A256GCM"
          })
          |> JOSE.JWE.compact()

        %{"type" => "jwk", "kid" => thumbprint(jwk), "jwe" => jwe}

      {:passphrase, pass} when is_binary(pass) and pass != "" ->
        ensure_pbes2_cap()

        {_, jwe} =
          JOSE.JWE.block_encrypt(JOSE.JWK.from_oct(pass), content_key, %{
            "alg" => @pass_wrap_alg,
            "enc" => "A256GCM",
            "p2c" => @pbes2_iterations
          })
          |> JOSE.JWE.compact()

        %{"type" => "passphrase", "jwe" => jwe}
    end)
  end

  @doc """
  Tries the entries addressed to the given secret; `:error` when none unwraps.
  A key entry is tried only when its `kid` is the thumbprint of the given key:
  jose 1.11 loops forever when asked to decrypt an ECDH-ES JWE with a key
  on another curve, so nothing else is ever attempted.
  """
  @spec unwrap_key([map], recipient) :: {:ok, <<_::256>>} | :error
  def unwrap_key(entries, secret) do
    ensure_pbes2_cap()

    candidates =
      case secret do
        {:jwk, %JOSE.JWK{} = jwk} ->
          kid = thumbprint(jwk)
          for %{"type" => "jwk", "kid" => ^kid, "jwe" => jwe} <- entries, do: {jwk, jwe}

        {:passphrase, pass} ->
          for %{"type" => "passphrase", "jwe" => jwe} <- entries,
              do: {JOSE.JWK.from_oct(pass), jwe}
      end

    Enum.find_value(candidates, :error, fn {jwk, jwe} ->
      try do
        case JOSE.JWE.block_decrypt(jwk, jwe) do
          {key, _} when is_binary(key) and byte_size(key) == 32 -> {:ok, key}
          _ -> nil
        end
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end
    end)
  end

  defp ephemeral_for(jwk) do
    case JOSE.JWK.to_map(jwk) do
      {_, %{"kty" => "EC", "crv" => "P-256"}} ->
        JOSE.JWK.generate_key({:ec, "P-256"})

      {_, %{"kty" => "OKP", "crv" => "X25519"}} ->
        JOSE.JWK.generate_key({:okp, :X25519})

      {_, %{"kty" => kty} = m} ->
        raise ArgumentError, "unsupported recipient key #{kty}/#{m["crv"]}"
    end
  end

  defp thumbprint(jwk), do: JOSE.JWK.thumbprint(JOSE.JWK.to_public(jwk))

  defp ensure_pbes2_cap do
    if :jose.pbes2_count_maximum() < @pbes2_iterations,
      do: :jose.pbes2_count_maximum(@pbes2_iterations)

    :ok
  end

  @doc """
  Parses a recipient key given as a file path or literal: a PEM (`-----BEGIN`)
  or a JWK JSON object. Public keys wrap; private keys unwrap.
  """
  @spec parse_jwk(String.t()) :: {:ok, JOSE.JWK.t()} | {:error, term}
  def parse_jwk(text_or_path) do
    text =
      if File.regular?(text_or_path), do: File.read!(text_or_path), else: text_or_path

    text = String.trim(text)

    try do
      cond do
        String.starts_with?(text, "-----BEGIN") ->
          case JOSE.JWK.from_pem(text) do
            %JOSE.JWK{} = jwk -> {:ok, jwk}
            _ -> {:error, :invalid_pem}
          end

        String.starts_with?(text, "{") ->
          {:ok, JOSE.JWK.from_map(Jason.decode!(text))}

        true ->
          {:error, :unrecognised_key_format}
      end
    rescue
      e -> {:error, {:invalid_key, Exception.message(e)}}
    end
  end

  # ------------------------------------------------------------- manifest JWS

  @doc "Signs `payload` (bytes) as a compact JWS with the instance signer; header carries `alg` and `kid` (the signer's `did:key`)."
  @spec sign(binary, Aerox.Crypto.Signer.signer()) :: {:ok, String.t()} | {:error, term}
  def sign(payload, signer) do
    did_key = Aerox.Crypto.Signer.did_key(signer)

    with {:ok, alg} <- KCrypto.did_key_alg(did_key) do
      header =
        Jason.encode!(%{"alg" => alg, "kid" => did_key, "typ" => "aerox-bundle-manifest+json"})

      input = b64(header) <> "." <> b64(payload)

      with {:ok, sig} <- Aerox.Crypto.Signer.sign(signer, input) do
        {:ok, input <> "." <> b64(sig)}
      end
    end
  end

  @doc "Verifies a compact JWS against the `did:key` in its own header; returns the payload and that key."
  @spec verify(String.t()) :: {:ok, binary, String.t()} | {:error, term}
  def verify(compact) when is_binary(compact) do
    with [h, p, s] <- String.split(compact, "."),
         {:ok, header_json} <- Base.url_decode64(h, padding: false),
         {:ok, payload} <- Base.url_decode64(p, padding: false),
         {:ok, sig} <- Base.url_decode64(s, padding: false),
         {:ok, %{"alg" => alg, "kid" => did_key}} <- Jason.decode(header_json),
         {:ok, ^alg} <- KCrypto.did_key_alg(did_key),
         true <- KCrypto.verify_did_sig(did_key, h <> "." <> p, sig) do
      {:ok, payload, did_key}
    else
      false -> {:error, :bad_signature}
      {:ok, _} -> {:error, :bad_jws_header}
      {:error, _} = e -> e
      _ -> {:error, :malformed_jws}
    end
  end

  def verify(_), do: {:error, :malformed_jws}

  defp b64(bytes), do: Base.url_encode64(bytes, padding: false)
end
