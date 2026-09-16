defmodule AeroxWeb.PDS.AdminTempTest do
  @moduledoc """
  The remaining `com.atproto` methods: admin.searchAccounts,
  admin.updateAccountSigningKey, and temp.addReservedHandle,
  checkHandleAvailability, revokeAccountCredentials, requestPhoneVerification
  (with createAccount's verification fields).
  """
  use AeroxWeb.ConnCase, async: false
  alias Aerox.ATProto.Crypto
  alias Aerox.PDS.{Accounts, ReservedKeys, Signup}

  setup %{conn: conn} do
    Aerox.RateLimit.reset()
    env = Application.get_env(:aerox, Aerox.PDS)
    Application.put_env(:aerox, Aerox.PDS, Keyword.put(env, :admin_password, "admin-for-tests-pds"))
    on_exit(fn -> Application.put_env(:aerox, Aerox.PDS, env) end)
    {:ok, conn: %{conn | host: "pds.aerox.sola.town"}, env: env}
  end

  defp admin(conn),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("admin:admin-for-tests-pds"))

  defp post_json(conn, method, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/xrpc/" <> method, Jason.encode!(body))
  end

  defp account(name, extra \\ %{}) do
    {:ok, a} =
      Signup.create(
        Map.merge(
          %{handle: "#{name}.test", email: "#{name}@example.com", password: "pw-#{name}-pw"},
          extra
        )
      )

    a
  end

  test "admin.searchAccounts: email substring, case-insensitive, paged", %{conn: conn} do
    a = account("findme-a")
    b = account("findme-b")
    _ = account("other-c")

    page = fn query ->
      conn |> admin() |> get("/xrpc/com.atproto.admin.searchAccounts?" <> URI.encode_query(query))
    end

    all = page.(%{email: "FINDME"}) |> json_response(200)
    assert all["accounts"] |> Enum.map(& &1["did"]) |> Enum.sort() == Enum.sort([a.did, b.did])

    first = page.(%{email: "findme", limit: 1}) |> json_response(200)
    assert [one] = first["accounts"]
    second = page.(%{email: "findme", limit: 1, cursor: first["cursor"]}) |> json_response(200)
    assert [two] = second["accounts"]
    assert Enum.sort([one["did"], two["did"]]) == Enum.sort([a.did, b.did])
    assert %{"email" => "findme-" <> _, "handle" => _} = one

    assert conn |> get("/xrpc/com.atproto.admin.searchAccounts?email=x") |> json_response(401)
  end

  test "admin.updateAccountSigningKey re-points the DID document, and adopts a reserved key", %{
    conn: conn
  } do
    %{did: did} = account("rekey")
    key = ReservedKeys.reserve()

    assert conn
           |> admin()
           |> post_json("com.atproto.admin.updateAccountSigningKey", %{did: did, signingKey: key})
           |> response(200)

    {:ok, doc} = Aerox.PLC.Directory.did_document(did)
    assert {:ok, ^key} = Aerox.ATProto.Identity.signing_did_key(doc)
    assert Crypto.did_key(Accounts.signing_keypair(did)) == key
    assert ReservedKeys.get(key) == nil

    # writes are signed with the new key
    {:ok, w} =
      Aerox.PDS.Records.Prepare.create(did, "app.bsky.feed.post", %{
        "$type" => "app.bsky.feed.post",
        "text" => "new key",
        "createdAt" => "2026-09-15T00:00:00.000Z"
      })

    {:ok, _} = Aerox.PDS.Records.process_writes(did, [w])
    root = Aerox.PDS.Records.root(did)
    {:ok, repo} = Aerox.ATProto.Repo.load(Aerox.PDS.Blockstore.new(did), root.cid)
    assert Aerox.ATProto.Repo.verify_commit_sig(repo.commit, key)

    assert conn
           |> admin()
           |> post_json("com.atproto.admin.updateAccountSigningKey", %{
             did: did,
             signingKey: "did:web:nope.test"
           })
           |> json_response(400)
  end

  test "temp.addReservedHandle and temp.checkHandleAvailability", %{conn: conn} do
    _ = account("taken")

    check = fn query ->
      conn
      |> get("/xrpc/com.atproto.temp.checkHandleAvailability?" <> URI.encode_query(query))
      |> json_response(200)
    end

    assert %{
             "handle" => "free-one.test",
             "result" => %{"$type" => "com.atproto.temp.checkHandleAvailability#resultAvailable"}
           } =
             check.(%{handle: "free-one.test"})

    taken =
      check.(%{
        handle: "taken.test",
        email: "Jane.Doe@example.com",
        birthDate: "1990-04-01T00:00:00.000Z"
      })

    assert taken["result"]["$type"] ==
             "com.atproto.temp.checkHandleAvailability#resultUnavailable"

    suggestions = taken["result"]["suggestions"]
    assert suggestions != [] and length(suggestions) <= 5
    assert %{"handle" => "janedoe.test", "method" => "email"} in suggestions
    assert Enum.all?(suggestions, &String.ends_with?(&1["handle"], ".test"))

    assert conn
           |> get("/xrpc/com.atproto.temp.checkHandleAvailability?handle=a.test&email=nope")
           |> json_response(400)
           |> Map.get("error") == "InvalidEmail"

    assert conn
           |> post_json("com.atproto.temp.addReservedHandle", %{handle: "vip.test"})
           |> json_response(401)

    assert conn
           |> admin()
           |> post_json("com.atproto.temp.addReservedHandle", %{handle: "VIP.test"})
           |> json_response(200) == %{}

    assert check.(%{handle: "vip.test"})["result"]["$type"] =~ "resultUnavailable"

    assert {:error, {"HandleNotAvailable", _}} =
             Signup.create(%{
               handle: "vip.test",
               email: "vip@example.com",
               password: "pw-pw-pw-pw"
             })
  end

  test "temp.revokeAccountCredentials: sessions, app passwords and the password stop working", %{
    conn: conn
  } do
    %{did: did, refresh_jwt: refresh} = account("revoked")
    {:ok, %{password: app_pw}} = Accounts.create_app_password(did, "app", false)

    login = fn pw ->
      conn
      |> post_json("com.atproto.server.createSession", %{identifier: "revoked.test", password: pw})
    end

    assert login.("pw-revoked-pw") |> json_response(200)
    assert login.(app_pw) |> json_response(200)

    assert conn
           |> admin()
           |> post_json("com.atproto.temp.revokeAccountCredentials", %{account: "revoked.test"})
           |> response(200)

    assert login.("pw-revoked-pw") |> json_response(401)
    assert login.(app_pw) |> json_response(401)

    assert conn
           |> put_req_header("authorization", "Bearer " <> refresh)
           |> post("/xrpc/com.atproto.server.refreshSession")
           |> json_response(400)
  end

  test "temp.requestPhoneVerification and createAccount's verification code", %{
    conn: conn,
    env: env
  } do
    # off by default
    refute conn
           |> get("/xrpc/com.atproto.server.describeServer")
           |> json_response(200)
           |> Map.get("phoneVerificationRequired")

    assert conn
           |> post_json("com.atproto.temp.requestPhoneVerification", %{
             phoneNumber: "+14155550123"
           })
           |> json_response(400)

    Application.put_env(
      :aerox,
      Aerox.PDS,
      env
      |> Keyword.put(:admin_password, "admin-for-tests-pds")
      |> Keyword.put(:phone_verification, adapter: Aerox.PDS.SMS.Log, notify: self())
    )

    assert conn
           |> get("/xrpc/com.atproto.server.describeServer")
           |> json_response(200)
           |> Map.get("phoneVerificationRequired")

    signup = fn extra ->
      post_json(
        conn,
        "com.atproto.server.createAccount",
        Map.merge(
          %{handle: "phoned.test", email: "phoned@example.com", password: "pw-pw-pw-pw"},
          extra
        )
      )
    end

    assert %{"error" => "InvalidPhoneVerification"} = signup.(%{}) |> json_response(400)

    assert %{"error" => "InvalidPhone"} =
             conn
             |> post_json("com.atproto.temp.requestPhoneVerification", %{phoneNumber: "555-0123"})
             |> json_response(400)

    assert conn
           |> post_json("com.atproto.temp.requestPhoneVerification", %{
             phoneNumber: "+1 (415) 555-0123"
           })
           |> response(200)

    assert_receive {:sms_code, "+14155550123", code}

    # once a minute per number
    assert conn
           |> post_json("com.atproto.temp.requestPhoneVerification", %{
             phoneNumber: "+14155550123"
           })
           |> json_response(429)

    wrong = if code == "000000", do: "111111", else: "000000"

    assert %{"error" => "InvalidPhoneVerification"} =
             signup.(%{verificationPhone: "+14155550123", verificationCode: wrong})
             |> json_response(400)

    assert %{"did" => _} =
             signup.(%{verificationPhone: "+14155550123", verificationCode: code})
             |> json_response(200)

    # the code is spent
    assert %{"error" => "InvalidPhoneVerification"} =
             post_json(conn, "com.atproto.server.createAccount", %{
               handle: "phoned2.test",
               email: "phoned2@example.com",
               password: "pw-pw-pw-pw",
               verificationPhone: "+14155550123",
               verificationCode: code
             })
             |> json_response(400)
  end
end
