defmodule Aerox.PDS.AccountsTest do
  @moduledoc "VERIFICATION §5 PDS: sessions, passwords and app passwords, email tokens, lifecycle transitions, preferences."
  use Aerox.DataCase, async: false, repos: [Aerox.PDS.Repo]
  alias Aerox.ATProto.Crypto
  alias Aerox.PDS.{Accounts, Sessions}

  @moduletag :service

  setup do
    kp = Crypto.generate(:k256)

    did =
      "did:plc:" <> (:crypto.strong_rand_bytes(15) |> Base.encode32(case: :lower, padding: false))

    n = System.unique_integer([:positive])

    {:ok, account} =
      Accounts.register(%{
        did: did,
        handle: "alice#{n}.test",
        signing_key: kp.private,
        email: "Alice#{n}@Example.com",
        password: "hunter2"
      })

    {:ok, did: did, account: account, handle: "alice#{n}.test", email: "alice#{n}@example.com"}
  end

  test "lookup by handle, did and email; email is lower-cased", %{
    did: did,
    handle: handle,
    email: email
  } do
    assert %{did: ^did, email: ^email} = Accounts.get_account(handle)
    assert %{did: ^did} = Accounts.get_account(did)
    assert %{did: ^did} = Accounts.get_by_email(String.upcase(email))
    assert Accounts.get_account("nobody.test") == nil
    assert {true, "active"} = Accounts.status(Accounts.get_account(did))
  end

  test "duplicate handle or email is refused", %{handle: handle, email: email} do
    kp = Crypto.generate(:k256)

    assert {:error, :handle_taken} =
             Accounts.register(%{
               did: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa",
               handle: handle,
               signing_key: kp.private
             })

    assert {:error, :email_taken} =
             Accounts.register(%{
               did: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb",
               handle: "other.test",
               signing_key: kp.private,
               email: email,
               password: "x"
             })
  end

  test "login: account password, then app passwords; wrong credentials never leak which", %{
    did: did,
    handle: handle,
    email: email
  } do
    assert {:ok, %{did: ^did}, nil} = Accounts.login(handle, "hunter2")
    assert {:ok, %{did: ^did}, nil} = Accounts.login(email, "hunter2")
    assert {:ok, %{did: ^did}, nil} = Accounts.login(did, "hunter2")
    assert {:error, :invalid_login} = Accounts.login(handle, "wrong")
    assert {:error, :invalid_login} = Accounts.login("nobody.test", "hunter2")
    assert {:error, :password_too_long} = Accounts.login(handle, String.duplicate("a", 513))

    {:ok, %{password: app_pw, name: "phone"}} = Accounts.create_app_password(did, "phone")
    assert Regex.match?(~r/^[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}$/, app_pw)
    assert {:ok, _, %{name: "phone", privileged: false}} = Accounts.login(handle, app_pw)
    assert {:error, :name_taken} = Accounts.create_app_password(did, "phone")
    assert [%{name: "phone"}] = Accounts.list_app_passwords(did)
    :ok = Accounts.revoke_app_password(did, "phone")
    assert {:error, :invalid_login} = Accounts.login(handle, app_pw)
  end

  test "sessions: access and refresh verify; refresh rotates with a grace period; revoke", %{
    did: did
  } do
    %{access_jwt: access, refresh_jwt: refresh} = Sessions.create_session(did)

    assert {:ok, %{"sub" => ^did, "scope" => "com.atproto.access"}} =
             Sessions.verify(access, "at+jwt")

    assert {:error, :bad_token_type} = Sessions.verify(access, "refresh+jwt")
    assert {:ok, %{"jti" => jti}} = Sessions.verify(refresh, "refresh+jwt")
    assert {:error, :invalid_token} = Sessions.verify(access <> "x", "at+jwt")

    assert {:ok, %{refresh_jwt: refresh2}} = Sessions.rotate(jti)
    {:ok, %{"jti" => jti2}} = Sessions.verify(refresh2, "refresh+jwt")
    # the old token still rotates during the grace period, to the same successor
    assert {:ok, %{refresh_jwt: refresh2b}} = Sessions.rotate(jti)
    assert {:ok, %{"jti" => ^jti2}} = Sessions.verify(refresh2b, "refresh+jwt")
    :ok = Sessions.revoke(jti2)
    assert nil == Sessions.rotate(jti2)

    # an app-password session carries the appPass scope
    {:ok, %{password: pw}} = Accounts.create_app_password(did, "app", true)
    {:ok, _, app} = Accounts.login(did, pw)
    %{access_jwt: a2} = Sessions.create_session(did, app)
    assert {:ok, %{"scope" => "com.atproto.appPassPrivileged"}} = Sessions.verify(a2, "at+jwt")
  end

  test "email tokens: single use, one per purpose, expiring, case-insensitive", %{
    did: did,
    email: email
  } do
    t1 = Accounts.create_email_token(did, "confirm_email")
    t2 = Accounts.create_email_token(did, "confirm_email")
    assert t1 != t2
    assert {:error, :invalid_token} = Accounts.assert_email_token(did, "confirm_email", t1)
    assert :ok = Accounts.assert_email_token(did, "confirm_email", String.downcase(t2))
    assert {:error, :invalid_token} = Accounts.assert_email_token(did, "reset_password", t2)
    assert :ok = Accounts.confirm_email(did, email, t2)
    assert %{email_confirmed_at: %DateTime{}} = Accounts.get_account(did)
    assert {:error, :invalid_token} = Accounts.confirm_email(did, email, t2)

    t3 = Accounts.create_email_token(did, "reset_password")

    Aerox.PDS.Repo.update_all(Aerox.PDS.Schema.EmailToken,
      set: [requested_at: DateTime.add(DateTime.utc_now(), -16 * 60)]
    )

    assert {:error, :expired_token} = Accounts.assert_email_token(did, "reset_password", t3)
    assert did == Accounts.did_for_email_token("reset_password", t3)
  end

  test "lifecycle: deactivate, activate, takedown revokes sessions, delete cascades", %{did: did} do
    %{refresh_jwt: refresh} = Sessions.create_session(did)
    {:ok, %{"jti" => jti}} = Sessions.verify(refresh, "refresh+jwt")

    :ok = Accounts.deactivate(did, nil)
    assert nil == Accounts.get_account(did)

    assert {false, "deactivated"} =
             Accounts.status(Accounts.get_account(did, include_deactivated: true))

    :ok = Accounts.activate(did)
    assert {true, "active"} = Accounts.status(Accounts.get_account(did))

    :ok = Accounts.set_takedown(did, "mod-123")
    assert nil == Accounts.get_account(did)

    assert {false, "takendown"} =
             Accounts.status(Accounts.get_account(did, include_taken_down: true))

    assert nil == Sessions.rotate(jti)
    :ok = Accounts.set_takedown(did, nil)

    :ok = Accounts.delete_account(did)
    assert nil == Accounts.get_account(did, include_taken_down: true, include_deactivated: true)
    assert {false, "deleted"} = Accounts.status(nil)
  end

  test "invite codes", %{did: did} do
    [code] = Accounts.create_invite_codes(did, 1, 1)
    assert :ok = Accounts.ensure_invite_available(code)
    kp = Crypto.generate(:k256)

    {:ok, _} =
      Accounts.register(%{
        did: "did:plc:cccccccccccccccccccccccc",
        handle: "invited.test",
        signing_key: kp.private,
        invite_code: code
      })

    assert {:error, {:invite, _}} = Accounts.ensure_invite_available(code)

    assert [%{code: ^code, uses: [%{used_by: "did:plc:cccccccccccccccccccccccc"}]}] =
             Accounts.account_invite_codes(did)
  end

  test "preferences: namespace, full-access filtering, declared age", %{did: did} do
    prefs = [
      %{"$type" => "app.bsky.actor.defs#adultContentPref", "enabled" => true},
      %{
        "$type" => "app.bsky.actor.defs#personalDetailsPref",
        "birthDate" => "2000-01-01T00:00:00.000Z"
      }
    ]

    assert :ok = Accounts.put_preferences(did, prefs, "app.bsky", true)

    assert {:error, "Some preferences are not" <> _} =
             Accounts.put_preferences(did, [%{"$type" => "chat.bsky.x"}], "app.bsky", true)

    assert {:error, "Do not have authorization" <> _} =
             Accounts.put_preferences(did, prefs, "app.bsky", false)

    all = Accounts.get_preferences(did, "app.bsky", true)

    assert Enum.map(all, & &1["$type"]) == [
             "app.bsky.actor.defs#adultContentPref",
             "app.bsky.actor.defs#personalDetailsPref",
             "app.bsky.actor.defs#declaredAgePref"
           ]

    assert %{"isOverAge18" => true} = List.last(all)
    limited = Accounts.get_preferences(did, "app.bsky", false)
    refute Enum.any?(limited, &(&1["$type"] == "app.bsky.actor.defs#personalDetailsPref"))

    # an app-password write must not wipe the full-access-only pref
    assert :ok =
             Accounts.put_preferences(
               did,
               [%{"$type" => "app.bsky.actor.defs#adultContentPref", "enabled" => false}],
               "app.bsky",
               false
             )

    assert Enum.any?(
             Accounts.get_preferences(did, "app.bsky", true),
             &(&1["$type"] == "app.bsky.actor.defs#personalDetailsPref")
           )
  end
end
