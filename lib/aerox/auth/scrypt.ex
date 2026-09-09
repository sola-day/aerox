defmodule Aerox.Auth.Scrypt do
  @moduledoc """
  Password hashing byte-for-byte compatible with the reference PDS
  (DESIGN §13.4; upstream `packages/pds/src/account-manager/helpers/scrypt.ts`).

  The stored form is `"<salt>:<hash>"` where both halves are lowercase hex:
  the salt is 16 random bytes rendered as 32 hex characters, and the hash is
  the 64-byte scrypt output with Node's defaults (N = 16384, r = 8, p = 1).
  Note that the *ASCII hex string* of the salt is what scrypt is fed as its
  salt bytes, not the decoded 16 bytes; this is upstream's (accidental)
  behaviour and any imported password hash depends on it.

  App passwords use a deterministic salt: the first 16 bytes of
  `sha256(did)`, hex-encoded, so that the same app password for the same DID
  hashes identically across imports.

  scrypt itself comes from the `scrypt` hex package, a NIF over Colin
  Percival's reference C implementation that runs on dirty CPU schedulers.
  """

  # Node's `crypto.scrypt` defaults, which upstream never overrides.
  @n 16_384
  @r 8
  @p 1
  @key_len 64
  @salt_bytes 16

  @new_password_max_length 256
  @old_password_max_length 512

  @doc "Maximum length of a password being *set* (upstream `NEW_PASSWORD_MAX_LENGTH`)."
  @spec new_password_max_length() :: pos_integer()
  def new_password_max_length, do: @new_password_max_length

  @doc """
  Maximum length of a password being *checked* (upstream
  `OLD_PASSWORD_MAX_LENGTH`); larger than the new-password limit so that
  passwords set before the limit was lowered still verify.
  """
  @spec old_password_max_length() :: pos_integer()
  def old_password_max_length, do: @old_password_max_length

  @doc """
  Hashes `password` under a fresh random 16-byte salt and returns the stored
  form `"<salt hex>:<hash hex>"`.
  """
  @spec gen_salt_and_hash(binary()) :: String.t()
  def gen_salt_and_hash(password) when is_binary(password) do
    salt = @salt_bytes |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    hash_with_salt(password, salt)
  end

  @doc """
  Hashes `password` under the given `salt` string (used verbatim as the scrypt
  salt bytes) and returns `"<salt>:<hash hex>"`.
  """
  @spec hash_with_salt(binary(), binary()) :: String.t()
  def hash_with_salt(password, salt) when is_binary(password) and is_binary(salt) do
    salt <> ":" <> derive_hex(password, salt)
  end

  @doc """
  Checks `password` against a stored `"<salt>:<hash hex>"`. The comparison of
  the derived hash is constant-time. A stored value without a `:` is simply
  rejected.
  """
  @spec verify(binary(), binary()) :: boolean()
  def verify(password, stored_hash) when is_binary(password) and is_binary(stored_hash) do
    # Upstream: `const [salt, hash] = storedHash.split(':')`, so any extra
    # segments are ignored, and a missing segment yields `undefined`, which
    # never equals a hex string.
    case String.split(stored_hash, ":") do
      [salt, hash | _] -> constant_time_equal?(hash, derive_hex(password, salt))
      _ -> false
    end
  end

  @doc """
  Hashes an app password under the DID-derived deterministic salt (the hex
  of the first 16 bytes of `sha256(did)`).
  """
  @spec hash_app_password(String.t(), binary()) :: String.t()
  def hash_app_password(did, password) when is_binary(did) and is_binary(password) do
    <<prefix::binary-size(@salt_bytes), _::binary>> = :crypto.hash(:sha256, did)
    hash_with_salt(password, Base.encode16(prefix, case: :lower))
  end

  defp derive_hex(password, salt) do
    password
    |> :scrypt.scrypt(salt, @n, @r, @p, @key_len)
    |> Base.encode16(case: :lower)
  end

  # `:crypto.hash_equals/2` requires equal sizes; the length of a stored hash
  # is not a secret, so checking it first leaks nothing.
  defp constant_time_equal?(a, b) when byte_size(a) == byte_size(b) do
    :crypto.hash_equals(a, b)
  end

  defp constant_time_equal?(_a, _b), do: false
end
