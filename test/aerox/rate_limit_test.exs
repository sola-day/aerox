defmodule Aerox.RateLimitTest do
  # Shares the global ETS table and touches application env: not async.
  use ExUnit.Case, async: false

  alias Aerox.RateLimit

  setup do
    RateLimit.reset()
    :ok
  end

  defp key, do: {:test, System.unique_integer([:positive])}

  describe "check/4" do
    test "allows up to the limit, reporting remaining, then denies with a retry" do
      key = key()

      assert {:allow, 2} = RateLimit.check(key, 60_000, 3)
      assert {:allow, 1} = RateLimit.check(key, 60_000, 3)
      assert {:allow, 0} = RateLimit.check(key, 60_000, 3)
      assert {:deny, retry_ms} = RateLimit.check(key, 60_000, 3)
      assert retry_ms > 0 and retry_ms <= 60_000
    end

    test "points cost counts against the limit" do
      key = key()

      assert {:allow, 2} = RateLimit.check(key, 60_000, 5, 3)
      assert {:allow, 0} = RateLimit.check(key, 60_000, 5, 2)
      assert {:deny, _} = RateLimit.check(key, 60_000, 5, 1)
    end

    test "keys are independent" do
      a = key()
      b = key()
      assert {:allow, 0} = RateLimit.check(a, 60_000, 1)
      assert {:deny, _} = RateLimit.check(a, 60_000, 1)
      assert {:allow, 0} = RateLimit.check(b, 60_000, 1)
    end
  end

  describe "limits/0" do
    test "mirrors upstream's numbers" do
      limits = RateLimit.limits()

      assert [%{scale_ms: 300_000, limit: 3000, key: :ip}] = limits.global_ip

      assert [
               %{scale_ms: 3_600_000, limit: 5000, key: :did},
               %{scale_ms: 86_400_000, limit: 35_000, key: :did}
             ] = limits.repo_write

      assert [%{scale_ms: 300_000, limit: 100, key: :ip}] = limits.create_account
      assert [%{scale_ms: 86_400_000, limit: 1000, key: :did}] = limits.upload_blob

      assert [
               %{scale_ms: 300_000, limit: 30, key: :identifier_ip},
               %{scale_ms: 86_400_000, limit: 300, key: :identifier_ip}
             ] = limits.create_session

      assert [
               %{scale_ms: 300_000, limit: 10, key: :did},
               %{scale_ms: 86_400_000, limit: 50, key: :did}
             ] = limits.update_handle

      for name <- [
            :request_email_confirmation,
            :request_password_reset,
            :request_email_update,
            :request_plc_operation_signature,
            :request_account_delete
          ] do
        assert [%{scale_ms: 60_000, limit: 15, key: :did}] = limits[name]
      end

      assert [%{scale_ms: 300_000, limit: 50, key: :ip}] = limits.reset_password
    end

    test "write points are create 3, update 2, delete 1" do
      assert RateLimit.write_points(:create) == 3
      assert RateLimit.write_points(:update) == 2
      assert RateLimit.write_points(:delete) == 1
    end

    test "config overrides replace a named limit's buckets" do
      original = Application.get_env(:aerox, RateLimit)
      on_exit(fn -> Application.put_env(:aerox, RateLimit, original) end)

      Application.put_env(:aerox, RateLimit,
        overrides: %{create_session: [%{scale_ms: 1000, limit: 1, key: :identifier_ip}]}
      )

      assert [%{limit: 1}] = RateLimit.limits().create_session
      assert [%{limit: 3000}] = RateLimit.limits().global_ip
    end

    test "fetch_limit!/1 raises on an unknown name" do
      assert_raise ArgumentError, ~r/unknown rate limit :nope/, fn ->
        RateLimit.fetch_limit!(:nope)
      end
    end
  end

  describe "hit_named/3" do
    test "reports the tightest bucket and denies when any bucket denies" do
      original = Application.get_env(:aerox, RateLimit)
      on_exit(fn -> Application.put_env(:aerox, RateLimit, original) end)

      Application.put_env(:aerox, RateLimit,
        overrides: %{
          update_handle: [
            %{scale_ms: 60_000, limit: 2, key: :did},
            %{scale_ms: 3_600_000, limit: 10, key: :did}
          ]
        }
      )

      did = "did:plc:#{System.unique_integer([:positive])}"

      assert {:allow, %{limit: 2, remaining: 1, scale_ms: 60_000, reset_ms: reset}} =
               RateLimit.hit_named(:update_handle, did)

      assert reset > 0 and reset <= 60_000
      assert {:allow, %{remaining: 0}} = RateLimit.hit_named(:update_handle, did)

      assert {:deny, %{limit: 2, remaining: 0, reset_ms: r}} =
               RateLimit.hit_named(:update_handle, did)

      assert r > 0
    end
  end
end
