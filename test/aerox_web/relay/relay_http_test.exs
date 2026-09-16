defmodule AeroxWeb.Relay.HttpTest do
  @moduledoc "The Relay's HTTP surface, dispatched by hostname (AeroxWeb.Dispatch), route for route with indigo."
  use AeroxWeb.ConnCase, async: false
  alias Aerox.Relay.{Accounts, Hosts}

  setup %{conn: conn} do
    Aerox.RateLimit.reset()
    {:ok, conn: %{conn | host: Aerox.Relay.Config.hostname()}}
  end

  defp admin(conn),
    do: put_req_header(conn, "authorization", "Basic " <> Base.encode64("admin:admin-for-tests-relay"))

  test "hostname dispatch: the relay host serves the relay router, others the PDS", %{conn: conn} do
    assert conn |> get("/_health") |> json_response(200) == %{"status" => "ok"}

    assert conn
           |> get("/.well-known/did.json")
           |> json_response(200)
           |> get_in(["service", Access.at(0), "type"]) == "AtprotoRelay"

    pds = %{conn | host: "pds.aerox.sola.town"}

    assert pds
           |> get("/xrpc/com.atproto.server.describeServer")
           |> json_response(200)
           |> Map.has_key?("availableUserDomains")

    # the relay does not serve the PDS's server methods
    assert conn
           |> get("/xrpc/com.atproto.server.describeServer")
           |> json_response(501)
           |> Map.get("error") == "MethodNotImplemented"
  end

  test "requestCrawl validates the host, applies limits, and lists it after events", %{conn: conn} do
    # the PDS is reachable through the test plug; it is subscribed (the consumer will fail to dial in test, harmlessly)
    resp =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(
        "/xrpc/com.atproto.sync.requestCrawl",
        Jason.encode!(%{"hostname" => "https://pds.aerox.sola.town"})
      )

    assert response(resp, 200)
    host = Hosts.get("pds.aerox.sola.town")

    assert host.status == "active" and
             host.account_limit == Aerox.Relay.Config.default_account_limit()

    assert Aerox.Relay.Consumers.subscribed?("pds.aerox.sola.town")
    Aerox.Relay.Consumers.unsubscribe("pds.aerox.sola.town")

    # not yet listed: no events received
    assert conn |> get("/xrpc/com.atproto.sync.listHosts") |> json_response(200) == %{
             "hosts" => []
           }

    Hosts.persist_cursor(host.id, 42)

    assert conn |> get("/xrpc/com.atproto.sync.listHosts") |> json_response(200) == %{
             "hosts" => [
               %{
                 "hostname" => "pds.aerox.sola.town",
                 "seq" => 42,
                 "status" => "active",
                 "accountCount" => 0
               }
             ]
           }

    assert conn
           |> get("/xrpc/com.atproto.sync.getHostStatus?hostname=pds.aerox.sola.town")
           |> json_response(200)
           |> Map.get("seq") == 42

    assert conn
           |> get("/xrpc/com.atproto.sync.getHostStatus?hostname=nope.example.com")
           |> json_response(404)
           |> Map.get("error") == "HostNotFound"

    # bad hostnames and unreachable hosts
    bad = fn h ->
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/xrpc/com.atproto.sync.requestCrawl", Jason.encode!(%{"hostname" => h}))
      |> json_response(400)
      |> Map.get("error")
    end

    assert bad.("not a host") == "BadRequest"
    assert bad.("http://localhost:1") == "BadRequest"
    # under the test plug every host reaches this endpoint; the relay's own
    # hostname answers describeServer with 501, so it is "not a PDS"
    assert bad.("https://relay.aerox.sola.town") == "HostNotFound"

    # banned domains
    :ok = Hosts.ban_domain("evil.example")

    assert conn
           |> put_req_header("content-type", "application/json")
           |> post(
             "/xrpc/com.atproto.sync.requestCrawl",
             Jason.encode!(%{"hostname" => "pds.evil.example"})
           )
           |> json_response(401)
           |> Map.get("error") == "DomainBan"

    # admin: limits and status
    assert conn
           |> admin()
           |> put_req_header("content-type", "application/json")
           |> post(
             "/xrpc/admin.setHostAccountLimit",
             Jason.encode!(%{"hostname" => "pds.aerox.sola.town", "accountLimit" => 5})
           )
           |> response(200)

    assert Hosts.get("pds.aerox.sola.town").account_limit == 5

    assert conn
           |> put_req_header("content-type", "application/json")
           |> post(
             "/xrpc/admin.setHostAccountLimit",
             Jason.encode!(%{"hostname" => "pds.aerox.sola.town", "accountLimit" => 5})
           )
           |> json_response(401)
  end

  test "repo views come from ingested state; content methods point at the PDS", %{conn: conn} do
    {:ok, host} = Hosts.create("pds.aerox.sola.town", false)
    before = Aerox.PDS.Sequencer.current() || 0

    {:ok, %{did: did}} =
      Aerox.PDS.Signup.create(%{
        handle: "viewed.aerox.sola.town",
        email: "v@example.com",
        password: "pw-pw-pw-pw"
      })

    for row <- Aerox.PDS.Sequencer.range(before, 100) do
      {t, body} = Aerox.PDS.Sequencer.Events.to_frame(row)
      :ok = Aerox.Relay.Ingest.process(host, t, body)
    end

    repo = Accounts.get_repo(Accounts.get(did).uid)

    assert conn |> get("/xrpc/com.atproto.sync.listRepos") |> json_response(200) == %{
             "repos" => [
               %{"did" => did, "head" => repo.commit_cid, "rev" => repo.rev, "active" => true}
             ]
           }

    assert conn |> get("/xrpc/com.atproto.sync.getRepoStatus?did=#{did}") |> json_response(200) ==
             %{"did" => did, "active" => true, "rev" => repo.rev}

    assert conn |> get("/xrpc/com.atproto.sync.getLatestCommit?did=#{did}") |> json_response(200) ==
             %{"cid" => repo.commit_cid, "rev" => repo.rev}

    assert conn
           |> get("/xrpc/com.atproto.sync.getLatestCommit?did=did:plc:aaaaaaaaaaaaaaaaaaaaaaaa")
           |> json_response(404)
           |> Map.get("error") == "RepoNotFound"

    # non-archival: repo content redirects to the hosting PDS, query intact
    for nsid <- ~w(getRepo getRecord getBlocks getBlob listBlobs) do
      resp = get(conn, "/xrpc/com.atproto.sync.#{nsid}?did=#{did}&since=abc")
      assert resp.status == 302

      assert get_resp_header(resp, "location") == [
               "https://pds.aerox.sola.town/xrpc/com.atproto.sync.#{nsid}?did=#{did}&since=abc"
             ]
    end

    assert conn
           |> get("/xrpc/com.atproto.sync.getRepo?did=did:plc:aaaaaaaaaaaaaaaaaaaaaaaa")
           |> json_response(404)
           |> Map.get("error") == "RepoNotFound"

    # a repo this relay has taken down is refused, not redirected
    :ok = Accounts.update_local_status(Accounts.get(did).uid, "takendown")

    assert conn
           |> get("/xrpc/com.atproto.sync.getRepo?did=#{did}")
           |> json_response(403)
           |> Map.get("error") == "RepoTakendown"

    :ok = Accounts.update_local_status(Accounts.get(did).uid, "active")

    assert conn |> get("/xrpc/com.atproto.sync.getHead?did=#{did}") |> json_response(501)

    # the relay firehose replays what was ingested
    relay_before = Aerox.Relay.Sequencer.current() - 4

    {:push, [], state} =
      AeroxWeb.Sockets.Firehose.init(%{cursor: relay_before, source: Aerox.Relay.Sequencer})

    assert_receive {:backfill, ^relay_before}
    {:push, frames, _} = AeroxWeb.Sockets.Firehose.handle_info({:backfill, relay_before}, state)

    types =
      for {:binary, f} <- frames, {:ok, {:message, t, _}} = Aerox.ATProto.Frame.decode(f), do: t

    assert types == ["#identity", "#account", "#commit", "#sync"]
  end
end
