defmodule AeroxWeb.IdentityResolutionTest do
  @moduledoc "com.atproto.identity.resolveDid / resolveIdentity / refreshIdentity on the PDS and the AppView."
  use AeroxWeb.ConnCase, async: false
  import Aerox.AppViewHelpers, only: [signup: 1]

  setup do
    Aerox.RateLimit.reset()
    # a fresh handle per test: the identity caches outlive the sandbox, and a
    # handle cached for an earlier test's (rolled back) DID would not match
    %{did: did, handle: handle} = signup("idres#{System.unique_integer([:positive])}")
    {:ok, did: did, handle: handle}
  end

  for {service, host} <- [pds: "pds.aerox.sola.town", appview: :appview] do
    describe "#{service}" do
      setup %{conn: conn} do
        host =
          case unquote(host) do
            :appview -> Aerox.AppView.Config.hostname()
            h -> h
          end

        {:ok, conn: %{conn | host: host}}
      end

      test "resolveDid returns the document; an unknown DID is DidNotFound", %{
        conn: conn,
        did: did
      } do
        body =
          conn |> get("/xrpc/com.atproto.identity.resolveDid?did=#{did}") |> json_response(200)

        assert body["didDoc"]["id"] == did

        assert %{"error" => "DidNotFound"} =
                 conn
                 |> get(
                   "/xrpc/com.atproto.identity.resolveDid?did=did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
                 )
                 |> json_response(404)

        assert conn |> get("/xrpc/com.atproto.identity.resolveDid?did=nope") |> json_response(400)
      end

      test "resolveIdentity from a DID and from a handle, verified both ways",
           %{conn: conn, did: did, handle: handle} do
        for identifier <- [did, handle, String.upcase(handle)] do
          body =
            conn
            |> get("/xrpc/com.atproto.identity.resolveIdentity?identifier=#{identifier}")
            |> json_response(200)

          assert body["did"] == did
          assert body["handle"] == handle
          assert body["didDoc"]["id"] == did
        end

        assert %{"error" => "HandleNotFound"} =
                 conn
                 |> get(
                   "/xrpc/com.atproto.identity.resolveIdentity?identifier=nobody.example.test"
                 )
                 |> json_response(404)
      end

      test "refreshIdentity re-resolves", %{conn: conn, did: did, handle: handle} do
        body =
          conn
          |> put_req_header("content-type", "application/json")
          |> post("/xrpc/com.atproto.identity.refreshIdentity", Jason.encode!(%{identifier: did}))
          |> json_response(200)

        assert body["did"] == did and body["handle"] == handle
      end
    end
  end

  test "a DID whose declared handle does not resolve back reports handle.invalid" do
    doc = %{
      "id" => "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb",
      "alsoKnownAs" => ["at://someone-else.example.test"]
    }

    # a cached document (the cache's ETS row shape: key, result, expires, stored)
    now = System.monotonic_time(:millisecond)
    table = :persistent_term.get({Aerox.Identity.Cache, Aerox.AppView.Identity, :table})
    :ets.insert(table, {{:did, doc["id"]}, {:ok, doc}, now + 60_000, now})

    assert {:ok, %{"handle" => "handle.invalid"}} =
             AeroxWeb.IdentityResolution.identity(Aerox.AppView.Identity, doc["id"], [])
  end
end
