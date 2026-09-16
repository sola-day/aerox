defmodule AeroxWeb.PDS.MigrationTest do
  @moduledoc """
  Account spec, "PDS Account Migration", inbound: a DID from another PDS
  reserves a signing key here, creates its account with a service JWT from
  itself (deactivated, no PLC operation), re-points its DID document at this
  PDS and that key, and activates. Plus the invite-code and signup-queue
  methods that sit beside createAccount.
  """
  use AeroxWeb.ConnCase, async: false
  alias Aerox.ATProto.Crypto
  alias Aerox.PDS.{Accounts, Config, ReservedKeys}
  alias Aerox.PLC.{Directory, Operations}

  setup %{conn: conn} do
    Aerox.RateLimit.reset()
    env = Application.get_env(:aerox, Aerox.PDS)
    Application.put_env(:aerox, Aerox.PDS, Keyword.put(env, :admin_password, "admin-for-tests-pds"))
    on_exit(fn -> Application.put_env(:aerox, Aerox.PDS, env) end)
    {:ok, conn: %{conn | host: "pds.aerox.sola.town"}}
  end

  defp post_json(conn, method, body, auth \\ nil) do
    conn
    |> then(&if(auth, do: put_req_header(&1, "authorization", auth), else: &1))
    |> put_req_header("content-type", "application/json")
    |> post("/xrpc/" <> method, Jason.encode!(body))
  end

  defp bearer(token), do: "Bearer " <> token
  defp admin, do: "Basic " <> Base.encode64("admin:admin-for-tests-pds")

  # an identity hosted elsewhere, in the same directory
  defp foreign_identity do
    rotation = Crypto.generate(:k256)
    old_signing = Crypto.generate(:k256)

    {genesis, did} =
      Operations.create_op(
        [
          signing_key: Crypto.did_key(old_signing),
          handle: "migrant.elsewhere.test",
          pds: "https://old-pds.elsewhere.test",
          rotation_keys: [Crypto.did_key(rotation)]
        ],
        rotation
      )

    {:ok, _} = Directory.submit(did, genesis)
    %{did: did, genesis: genesis, rotation: rotation, old_signing: old_signing}
  end

  test "reserve a key, create the account with service auth, re-point the DID, activate", %{
    conn: conn
  } do
    %{did: did, genesis: genesis, rotation: rotation, old_signing: old_signing} =
      foreign_identity()

    key =
      conn |> post_json("com.atproto.server.reserveSigningKey", %{did: did}) |> json_response(200)

    assert %{"signingKey" => "did:key:" <> _ = reserved} = key
    # reserving again for the same DID returns the same key
    assert conn
           |> post_json("com.atproto.server.reserveSigningKey", %{did: did})
           |> json_response(200) == key

    account = %{
      did: did,
      handle: "migrant.test",
      email: "migrant@example.com",
      password: "correct horse battery staple"
    }

    # bringing a DID without its authorisation is refused
    assert %{"error" => "AuthenticationRequired"} =
             conn |> post_json("com.atproto.server.createAccount", account) |> json_response(401)

    jwt =
      Aerox.Auth.ServiceJWT.create(
        keypair: old_signing,
        iss: did,
        aud: Config.service_did(),
        lxm: "com.atproto.server.createAccount"
      )

    created =
      conn
      |> post_json("com.atproto.server.createAccount", account, bearer(jwt))
      |> json_response(200)

    assert created["did"] == did and created["handle"] == "migrant.test"
    access = created["accessJwt"]

    # deactivated, holding the reserved key, and not up for reaping
    status =
      conn
      |> put_req_header("authorization", bearer(access))
      |> get("/xrpc/com.atproto.server.checkAccountStatus")
      |> json_response(200)

    assert status["activated"] == false
    assert Crypto.did_key(Accounts.signing_keypair(did)) == reserved
    assert ReservedKeys.get(did) == nil
    assert Aerox.PDS.Signup.reap_orphans() |> Enum.member?(did) == false

    # the recommended credentials name the reserved key and this PDS
    creds =
      conn
      |> put_req_header("authorization", bearer(access))
      |> get("/xrpc/com.atproto.identity.getRecommendedDidCredentials")
      |> json_response(200)

    assert creds["verificationMethods"]["atproto"] == reserved

    # activating before the DID document points here is refused
    assert conn
           |> post_json("com.atproto.server.activateAccount", %{}, bearer(access))
           |> json_response(400)

    update =
      Operations.atproto_update_op(genesis, rotation,
        signing_key: reserved,
        pds: Config.public_url(),
        handle: "migrant.test"
      )

    {:ok, _} = Directory.submit(did, update, DateTime.add(DateTime.utc_now(), 1))
    Aerox.Identity.invalidate(Aerox.PDS.Identity, did)

    assert conn
           |> post_json("com.atproto.server.activateAccount", %{}, bearer(access))
           |> response(200)

    assert conn
           |> put_req_header("authorization", bearer(access))
           |> get("/xrpc/com.atproto.server.checkAccountStatus")
           |> json_response(200)
           |> Map.get("activated")
  end

  test "createInviteCodes and getInviteCodes (admin), checkSignupQueue", %{conn: conn} do
    create = fn body ->
      conn
      |> post_json("com.atproto.server.createInviteCodes", body, admin())
      |> json_response(200)
      |> Map.get("codes")
    end

    assert [%{"account" => "did:plc:" <> _, "codes" => c1}] =
             create.(%{
               codeCount: 3,
               useCount: 2,
               forAccounts: ["did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"]
             })

    # without forAccounts the codes belong to the admin pseudo-account
    assert [%{"account" => "admin", "codes" => c2}] = create.(%{codeCount: 3, useCount: 2})

    assert length(c1) == 3 and length(c2) == 3

    assert conn
           |> post_json("com.atproto.server.createInviteCodes", %{codeCount: 1, useCount: 1})
           |> json_response(401)

    # one use, so it sorts first by usage
    used = hd(c2)

    {:ok, %{access_jwt: access}} =
      Aerox.PDS.Signup.create(%{
        handle: "invited.test",
        email: "invited@example.com",
        password: "pw-pw-pw-pw",
        invite_code: used
      })

    admin_get = fn query ->
      conn
      |> put_req_header("authorization", admin())
      |> get("/xrpc/com.atproto.admin.getInviteCodes?" <> URI.encode_query(query))
    end

    all = admin_get.(%{limit: 100}) |> json_response(200)
    assert MapSet.subset?(MapSet.new(c1 ++ c2), MapSet.new(all["codes"], & &1["code"]))

    # recent: newest first, paged by cursor without gaps or repeats
    page1 = admin_get.(%{limit: 4}) |> json_response(200)
    page2 = admin_get.(%{limit: 100, cursor: page1["cursor"]}) |> json_response(200)
    codes = Enum.map(page1["codes"] ++ page2["codes"], & &1["code"])
    assert codes == Enum.map(all["codes"], & &1["code"])

    by_usage = admin_get.(%{sort: "usage", limit: 1}) |> json_response(200)
    assert [%{"code" => ^used, "uses" => [%{"usedBy" => _}]}] = by_usage["codes"]

    assert [_] =
             (admin_get.(%{sort: "usage", limit: 1, cursor: by_usage["cursor"]})
              |> json_response(200))["codes"]

    assert admin_get.(%{sort: "nope"}) |> json_response(400)
    assert admin_get.(%{cursor: "garbage"}) |> json_response(400)

    assert conn
           |> put_req_header("authorization", bearer(access))
           |> get("/xrpc/com.atproto.temp.checkSignupQueue")
           |> json_response(200) == %{"activated" => true}
  end
end
