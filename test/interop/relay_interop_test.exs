defmodule Aerox.Interop.RelayTest do
  @moduledoc """
  VERIFICATION §7.2 rows "indigo relay" (it accepts our PDS) and "Reference
  PDS" (our Relay ingests it), plus §7.3 "being crawled" / "crawling", over
  real hostnames and TLS against the containers in tools/interop/compose.yaml:

      AEROX_PDS_URL=https://pds.aerox.sola.town \\
      AEROX_RELAY_URL=https://relay.aerox.sola.town \\
      AEROX_REF_PDS_URL=https://ref-pds.aerox.sola.town \\
      AEROX_REF_RELAY_URL=https://ref-relay.aerox.sola.town \\
      AEROX_REF_PDS_IDENTIFIER=refalice.ref-pds.aerox.sola.town \\
      AEROX_REF_PDS_PASSWORD=... mix test --only interop

  Both relays must already be subscribed to both PDSs (requestCrawl once).
  """
  use ExUnit.Case, async: false
  @moduletag :interop

  setup_all do
    env = fn k -> System.get_env(k) end

    if Enum.all?(~w(AEROX_PDS_URL AEROX_RELAY_URL AEROX_REF_PDS_URL AEROX_REF_RELAY_URL), env) do
      {:ok,
       pds: env.("AEROX_PDS_URL"),
       relay: env.("AEROX_RELAY_URL"),
       ref_pds: env.("AEROX_REF_PDS_URL"),
       ref_relay: env.("AEROX_REF_RELAY_URL"),
       ref_identifier: env.("AEROX_REF_PDS_IDENTIFIER"),
       ref_password: env.("AEROX_REF_PDS_PASSWORD")}
    else
      {:ok, skip: true}
    end
  end

  defp xrpc_get(base, method, params) do
    Req.get!("#{base}/xrpc/#{method}", params: params, retry: false)
  end

  defp xrpc_post(base, method, body, token \\ nil) do
    headers = if token, do: [{"authorization", "Bearer " <> token}], else: []
    Req.post!("#{base}/xrpc/#{method}", json: body, headers: headers, retry: false)
  end

  defp create_post(pds, did, jwt, text) do
    resp =
      xrpc_post(
        pds,
        "com.atproto.repo.createRecord",
        %{
          "repo" => did,
          "collection" => "app.bsky.feed.post",
          "record" => %{
            "$type" => "app.bsky.feed.post",
            "text" => text,
            "createdAt" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        },
        jwt
      )

    assert resp.status == 200, inspect(resp.body)
    resp.body["commit"]
  end

  defp wait_for(fun, tries \\ 40) do
    case fun.() do
      {:ok, v} ->
        v

      _ when tries > 0 ->
        Process.sleep(500)
        wait_for(fun, tries - 1)

      other ->
        flunk("timed out: #{inspect(other)}")
    end
  end

  # waits until the relay's latest commit for the DID is the one we just made
  defp latest_commit(relay, did, rev) do
    fn ->
      resp = xrpc_get(relay, "com.atproto.sync.getLatestCommit", did: did)

      if resp.status == 200 and resp.body["rev"] == rev,
        do: {:ok, resp.body},
        else: {:pending, resp.body}
    end
  end

  test "the indigo relay accepts our PDS: a fresh account's commit reaches it, host is listed",
       ctx do
    if ctx[:skip], do: raise(ExUnit.AssertionError, "interop env not set")

    handle = "interop-#{System.unique_integer([:positive])}.aerox.sola.town"

    created =
      xrpc_post(ctx.pds, "com.atproto.server.createAccount", %{
        "handle" => handle,
        "email" => "#{handle}@example.invalid",
        "password" => "interop-password"
      })

    assert created.status == 200, inspect(created.body)
    %{"did" => did, "accessJwt" => jwt} = created.body
    commit = create_post(ctx.pds, did, jwt, "interop: hello indigo relay")

    for relay <- [ctx.ref_relay, ctx.relay] do
      latest = wait_for(latest_commit(relay, did, commit["rev"]))

      assert latest["rev"] == commit["rev"],
             "#{relay} has #{inspect(latest)} expected #{inspect(commit)}"

      assert latest["cid"] == commit["cid"]

      hosts = xrpc_get(relay, "com.atproto.sync.listHosts", %{}).body["hosts"]
      our_host = URI.parse(ctx.pds).host

      assert Enum.any?(hosts, &(&1["hostname"] == our_host and &1["status"] == "active")),
             inspect(hosts)
    end
  end

  test "our Relay ingests the reference PDS: its account's commit is verified and listed", ctx do
    if ctx[:skip], do: raise(ExUnit.AssertionError, "interop env not set")

    if is_nil(ctx.ref_identifier) or is_nil(ctx.ref_password),
      do: raise(ExUnit.AssertionError, "AEROX_REF_PDS_IDENTIFIER/PASSWORD not set")

    session =
      xrpc_post(ctx.ref_pds, "com.atproto.server.createSession", %{
        "identifier" => ctx.ref_identifier,
        "password" => ctx.ref_password
      })

    assert session.status == 200, inspect(session.body)
    %{"did" => did, "accessJwt" => jwt} = session.body
    commit = create_post(ctx.ref_pds, did, jwt, "interop: hello aerox relay")

    latest = wait_for(latest_commit(ctx.relay, did, commit["rev"]))
    assert latest["rev"] == commit["rev"] and latest["cid"] == commit["cid"]

    status = xrpc_get(ctx.relay, "com.atproto.sync.getRepoStatus", did: did).body
    assert status["active"] == true and status["rev"] == commit["rev"]

    ref_host = URI.parse(ctx.ref_pds).host
    hosts = xrpc_get(ctx.relay, "com.atproto.sync.listHosts", %{}).body["hosts"]
    assert Enum.any?(hosts, &(&1["hostname"] == ref_host and &1["status"] == "active"))
  end
end
