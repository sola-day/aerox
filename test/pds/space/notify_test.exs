defmodule Aerox.PDS.Space.NotifyTest do
  @moduledoc """
  DESIGN §12.5 R9: outbound Spaces notifications are Oban jobs signed with a
  service JWT; failures are errors (retried, dead-lettered by Oban after
  `max_attempts`). And the `managing-app` mint policy asks the app over
  `checkUserAccess` with service auth from the authority.
  """
  use Aerox.DataCase, async: false
  use Oban.Testing, repo: Aerox.PDS.Repo, prefix: false

  alias Aerox.PDS.Space.{Credentials, Notify, Policy, Spaces}

  defmodule Sink do
    @moduledoc false
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(opts[:pid], {:request, conn.method, conn.request_path, conn.req_headers, body})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(opts[:status] || 200, opts[:body] || "{}")
    end
  end

  setup do
    {:ok, %{did: owner}} =
      Aerox.PDS.Signup.create(%{
        handle: "notify-owner.test",
        email: "notify-owner@example.com",
        password: "correct-horse"
      })

    {:ok, %{did: member}} =
      Aerox.PDS.Signup.create(%{
        handle: "notify-member.test",
        email: "notify-member@example.com",
        password: "correct-horse"
      })

    http = Application.get_env(:aerox, Aerox.Identity.HTTP)
    on_exit(fn -> Application.put_env(:aerox, Aerox.Identity.HTTP, http) end)
    {:ok, owner: owner, member: member, http: http}
  end

  defp sink(http, opts) do
    Application.put_env(
      :aerox,
      Aerox.Identity.HTTP,
      Keyword.put(http, :plug, {Sink, Keyword.put(opts, :pid, self())})
    )
  end

  test "Deliver signs a service JWT for the registered service and posts the body", ctx do
    %{owner: owner, http: http} = ctx
    sink(http, [])
    space = "at://#{owner}/space/my.bulletin.board/self"

    assert :ok =
             perform_job(Notify.Deliver, %{
               iss: owner,
               aud: "did:web:app.example#bulletin",
               url: "https://app.example/xrpc/com.atproto.space.notifyWrite",
               lxm: "com.atproto.space.notifyWrite",
               body: %{space: space, repo: owner, rev: "3mv4fihuqwc2h"}
             })

    assert_receive {:request, "POST", "/xrpc/com.atproto.space.notifyWrite", headers, body}
    assert Jason.decode!(body) == %{"space" => space, "repo" => owner, "rev" => "3mv4fihuqwc2h"}
    {"authorization", "Bearer " <> jwt} = List.keyfind(headers, "authorization", 0)

    # the recipient verifies it as bulletin does: aud = its service identifier, lxm = the method
    resolver = fn did, _ -> Aerox.Identity.resolve_signing_key(Aerox.PDS.Identity, did, []) end

    assert {:ok, %{iss: ^owner, aud: "did:web:app.example#bulletin"}} =
             Aerox.Auth.ServiceJWT.verify(
               jwt,
               "did:web:app.example#bulletin",
               "com.atproto.space.notifyWrite",
               resolver
             )
  end

  test "a failed delivery is an error, so Oban retries and then discards", ctx do
    %{owner: owner, http: http} = ctx
    sink(http, status: 503)

    assert {:error, {:http, 503, _}} =
             perform_job(Notify.Deliver, %{
               iss: owner,
               aud: "did:web:app.example#bulletin",
               url: "https://app.example/xrpc/com.atproto.space.notifyWrite",
               lxm: "com.atproto.space.notifyWrite",
               body: %{space: "at://#{owner}/space/t.b/self", repo: owner, rev: "3mv4fihuqwc2h"}
             })

    assert Notify.Deliver.__opts__()[:max_attempts] == 5
  end

  test "notifyWrite from a writer's PDS goes to the space host resolved from the space DID",
       ctx do
    %{owner: owner, member: member, http: http} = ctx
    space = "at://#{owner}/space/my.bulletin.board/self"
    {:ok, _} = Spaces.create(owner, space, true)
    # the owner's PDS is this PDS: resolved through the DID document
    assert {:ok, "https://pds.aerox.sola.town"} = Notify.resolve_service_endpoint(owner)

    sink(http, [])

    assert :ok =
             perform_job(Notify.NotifyWrite, %{space: space, repo: member, rev: "3mv4fihuqwc2h"})

    assert_receive {:request, "POST", "/xrpc/com.atproto.space.notifyWrite", headers, _}
    {"authorization", "Bearer " <> jwt} = List.keyfind(headers, "authorization", 0)
    resolver = fn did, _ -> Aerox.Identity.resolve_signing_key(Aerox.PDS.Identity, did, []) end

    assert {:ok, %{iss: ^member, aud: ^owner}} =
             Aerox.Auth.ServiceJWT.verify(jwt, owner, "com.atproto.space.notifyWrite", resolver)
  end

  test "the managing-app policy asks checkUserAccess with the authority's service auth", ctx do
    %{owner: owner, member: member, http: http} = ctx
    space = "at://#{owner}/space/my.bulletin.board/self"

    # the managing app is identified by a service entry; here the owner's own
    # PDS entry stands in for it (a bare DID resolves to #atproto_pds)
    {:ok, row} =
      Spaces.create(owner, space, true, %{mint_policy: "managing-app", managing_app: owner})

    sink(http, body: ~s({"authorized": true}))
    assert :ok = Policy.authorize_user(row, member, "https://app.example/client")
    assert_receive {:request, "GET", "/xrpc/com.atproto.simplespace.checkUserAccess", headers, _}
    {"authorization", "Bearer " <> jwt} = List.keyfind(headers, "authorization", 0)
    resolver = fn did, _ -> Aerox.Identity.resolve_signing_key(Aerox.PDS.Identity, did, []) end

    assert {:ok, %{iss: ^owner}} =
             Aerox.Auth.ServiceJWT.verify(
               jwt,
               owner,
               "com.atproto.simplespace.checkUserAccess",
               resolver
             )

    sink(http, body: ~s({"authorized": false}))
    assert {:error, :user_not_authorized} = Policy.authorize_user(row, member, "x")

    sink(http, status: 500)
    assert {:error, :user_not_authorized} = Policy.authorize_user(row, member, "x")
  end

  test "delegation tokens and space credentials round-trip, expire, and are single-use", ctx do
    %{owner: owner, member: member} = ctx
    space = "at://#{owner}/space/my.bulletin.board/self"
    mk = Aerox.PDS.Accounts.signing_keypair(member)
    ok = Aerox.PDS.Accounts.signing_keypair(owner)
    aud = Credentials.space_host_aud(owner)

    token = Credentials.create_delegation(%{iss: member, space: space, aud: aud}, mk)

    assert {:ok, %{iss: ^member, sub: ^space, aud: ^aud}} =
             Credentials.verify_delegation(token, sub: space, aud: aud)

    # single use
    assert {:error, {"BadJwtReplay", _}} = Credentials.verify_delegation(token)

    assert {:error, {"BadJwtSub", _}} =
             Credentials.verify_delegation(token, sub: space <> "2", replay: false)

    assert {:error, {"BadJwtAudience", _}} =
             Credentials.verify_delegation(token,
               aud: "did:web:other#atproto_space_host",
               replay: false
             )

    # a delegation token is not a credential (and lacks cnf), and vice versa
    assert {:error, {"BadJwtType", _}} = Credentials.verify_credential(token)

    cred = Credentials.create_credential(%{iss: owner, space: space, jkt: "thumb"}, ok)
    assert {:ok, %{iss: ^owner, sub: ^space, jkt: "thumb"}} = Credentials.verify_credential(cred)
    assert {:error, {"BadJwtType", _}} = Credentials.verify_delegation(cred)

    assert {:error, {"JwtExpired", _}} =
             Credentials.verify_credential(cred, now: System.os_time(:second) + 7300)

    # signed by the wrong key
    forged = Credentials.create_credential(%{iss: owner, space: space, jkt: "thumb"}, mk)
    assert {:error, {"BadJwtSignature", _}} = Credentials.verify_credential(forged)
  end
end
