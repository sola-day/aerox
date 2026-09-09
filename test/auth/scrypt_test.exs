defmodule Aerox.Auth.ScryptTest do
  @moduledoc """
  Oracle: `test/golden/auth/scrypt-vectors.json`, produced by Node's
  `crypto.scrypt` with the defaults upstream relies on (DESIGN §13.4).
  """
  use Aerox.GoldenCase, async: true

  alias Aerox.Auth.Scrypt

  @vectors json_golden!("auth/scrypt-vectors.json")

  describe "hash_with_salt/2" do
    for %{"name" => name} = v <- @vectors do
      test "matches the Node oracle: #{name}" do
        %{"password" => password, "salt" => salt, "expected" => expected} =
          unquote(Macro.escape(v))

        assert Scrypt.hash_with_salt(password, salt) == expected
      end
    end
  end

  describe "verify/2" do
    for %{"name" => name} = v <- @vectors do
      test "accepts the stored hash: #{name}" do
        %{"password" => password, "expected" => expected} = unquote(Macro.escape(v))
        assert Scrypt.verify(password, expected)
      end

      test "rejects a wrong password: #{name}" do
        %{"password" => password, "expected" => expected} = unquote(Macro.escape(v))
        refute Scrypt.verify(password <> "x", expected)
        refute Scrypt.verify("not the password", expected)
      end
    end

    test "rejects a malformed stored hash" do
      [%{"password" => password, "expected" => expected} | _] = @vectors
      [salt, hash] = String.split(expected, ":")

      refute Scrypt.verify(password, "")
      refute Scrypt.verify(password, "no-colon-at-all")
      refute Scrypt.verify(password, hash)
      refute Scrypt.verify(password, salt <> ":")
      refute Scrypt.verify(password, salt <> ":" <> String.slice(hash, 0..-2//1))
      refute Scrypt.verify(password, salt <> ":" <> String.upcase(hash))
    end

    test "ignores trailing segments like upstream's destructuring split" do
      [%{"password" => password, "expected" => expected} | _] = @vectors
      assert Scrypt.verify(password, expected <> ":junk")
    end
  end

  describe "gen_salt_and_hash/1" do
    test "produces a verifiable hash under a fresh 32-hex-char salt" do
      stored = Scrypt.gen_salt_and_hash("hunter2")
      assert [salt, hash] = String.split(stored, ":")
      assert byte_size(salt) == 32
      assert salt =~ ~r/\A[0-9a-f]{32}\z/
      assert hash =~ ~r/\A[0-9a-f]{128}\z/
      assert Scrypt.verify("hunter2", stored)
      refute Scrypt.verify("hunter3", stored)
      assert Scrypt.hash_with_salt("hunter2", salt) == stored
    end

    test "uses a different salt each time" do
      refute Scrypt.gen_salt_and_hash("hunter2") == Scrypt.gen_salt_and_hash("hunter2")
    end
  end

  describe "hash_app_password/2" do
    test "matches the Node oracle for the DID-derived salt" do
      vectors = Enum.filter(@vectors, &Map.has_key?(&1, "appPasswordDid"))
      assert vectors != []

      for %{
            "appPasswordDid" => did,
            "password" => password,
            "expected" => expected,
            "salt" => salt
          } <-
            vectors do
        assert Scrypt.hash_app_password(did, password) == expected
        assert String.starts_with?(expected, salt <> ":")
        assert Scrypt.verify(password, expected)
      end
    end
  end

  describe "limits" do
    test "match upstream's constants" do
      assert Scrypt.new_password_max_length() == 256
      assert Scrypt.old_password_max_length() == 512
    end

    test "the corpus exercises a password at the new-password limit" do
      assert Enum.any?(@vectors, &(String.length(&1["password"]) == 256))
    end
  end
end
