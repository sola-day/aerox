Code.require_file("../../labeler/helpers.exs", __DIR__)

defmodule AeroxWeb.Labeler.ScenarioTest do
  @moduledoc """
  VERIFICATION §6 scenario 7 against the in-process stack: accounts and a
  post through the PDS, indexed into the AppView; the labeler applies a
  label → `getPosts` shows it under `atproto-accept-labelers`; a report
  round-trips (createReport via the PDS proxy → labeler → queryReports);
  a record takedown hides the post on the PDS and in the AppView.
  """
  use AeroxWeb.ConnCase, async: false
  alias Aerox.AppView.Repo, as: AppViewRepo
  alias Aerox.AppView.Schema, as: S
  alias Aerox.Labeler.Sequencer
  import Aerox.AppViewHelpers, only: [signup: 1, write!: 2, ingest_since: 1, create: 3, now: 0]
  import Aerox.LabelerTestHelpers

  setup %{conn: conn} do
    labeler = ensure_labeler!()
    since = Aerox.PDS.Sequencer.current() || 0
    alice = signup("alice-sc")
    bob = signup("bob-sc")
    ingest_since(since)
    {:ok, conn: conn, labeler: labeler, alice: alice, bob: bob}
  end

  defp host(conn, service) do
    hostname =
      case service do
        :pds -> Aerox.PDS.Config.hostname()
        :appview -> Aerox.AppView.Config.hostname()
        :labeler -> Aerox.Labeler.Config.hostname()
      end

    %{conn | host: hostname}
  end

  defp post_json(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  defp get_posts(conn, uri, headers) do
    Enum.reduce(headers, host(conn, :appview), fn {k, v}, c -> put_req_header(c, k, v) end)
    |> get("/xrpc/app.bsky.feed.getPosts?uris=#{URI.encode_www_form(uri)}")
    |> json_response(200)
  end

  # the label frames the AppView consumer would receive, applied through its handler
  defp consume_labels(since, labeler_did) do
    state = %{did: labeler_did, cursor: 0}

    for row <- Sequencer.range(since, 100), reduce: state do
      st ->
        {t, body} = Sequencer.to_frame(row)
        Aerox.AppView.Labels.Consumer.handle_frame({:message, t, body}, st)
    end
  end

  test "label → AppView view; report round-trip through the PDS proxy; record takedown hides the post everywhere",
       ctx do
    %{conn: conn, alice: alice, bob: bob, labeler: labeler} = ctx

    post =
      create(alice.did, "app.bsky.feed.post", %{"text" => "buy my coins", "createdAt" => now()})

    write!(alice.did, [post])
    label_since = Sequencer.current() || 0
    admin = conn |> host(:labeler) |> put_req_header("authorization", admin_auth())

    strong_ref = %{
      "$type" => "com.atproto.repo.strongRef",
      "uri" => post.uri,
      "cid" => to_string(post.cid)
    }

    # -- 1. the labeler applies a label; the AppView shows it under the accepted labelers
    assert %{"action" => "label"} =
             admin
             |> post_json("/xrpc/aerox.moderation.emitEvent", %{
               "action" => "label",
               "subject" => strong_ref,
               "meta" => %{"val" => "spam"}
             })
             |> json_response(200)

    %{cursor: cursor} = consume_labels(label_since, labeler.did)
    assert cursor > label_since
    assert [%S.Label{val: "spam", neg: false, cid: cid}] = AppViewRepo.all(S.Label)
    assert cid == to_string(post.cid)

    body = get_posts(conn, post.uri, [{"atproto-accept-labelers", labeler.did}])
    assert [%{"uri" => uri, "labels" => [label]}] = body["posts"]
    assert uri == post.uri
    assert %{"src" => src, "uri" => ^uri, "val" => "spam", "cts" => _} = label
    assert src == labeler.did

    # the default set includes our labeler; another labeler's set does not show it
    assert [%{"labels" => [_]}] = get_posts(conn, post.uri, [])["posts"]

    assert [%{"labels" => []}] =
             get_posts(conn, post.uri, [{"atproto-accept-labelers", "did:web:other.example"}])[
               "posts"
             ]

    # negation reaches the AppView the same way
    assert %{"action" => "unlabel"} =
             admin
             |> post_json("/xrpc/aerox.moderation.emitEvent", %{
               "action" => "unlabel",
               "subject" => strong_ref,
               "meta" => %{"val" => "spam"}
             })
             |> json_response(200)

    consume_labels(cursor, labeler.did)
    assert [%S.Label{val: "spam", neg: true}] = AppViewRepo.all(S.Label)

    assert [%{"labels" => []}] =
             get_posts(conn, post.uri, [{"atproto-accept-labelers", labeler.did}])["posts"]

    # -- 2. bob reports the post through his PDS: proxied to the labeler with a service JWT
    report =
      conn
      |> host(:pds)
      |> put_req_header("authorization", "Bearer " <> bob.access_jwt)
      |> post_json("/xrpc/com.atproto.moderation.createReport", %{
        "reasonType" => "com.atproto.moderation.defs#reasonSpam",
        "reason" => "coins",
        "subject" => strong_ref
      })
      |> json_response(200)

    assert %{"id" => report_id, "reportedBy" => reporter, "subject" => %{"uri" => report_uri}} =
             report

    assert reporter == bob.did and report_uri == post.uri

    reports =
      admin
      |> get("/xrpc/aerox.moderation.queryReports?subject=#{URI.encode_www_form(post.uri)}")
      |> json_response(200)

    assert [%{"id" => ^report_id, "reportedBy" => ^reporter, "reason" => "coins"}] =
             reports["reports"]

    assert %{"action" => "acknowledge"} =
             admin
             |> post_json("/xrpc/aerox.moderation.emitEvent", %{
               "action" => "acknowledge",
               "subject" => strong_ref,
               "meta" => %{"report" => report_id}
             })
             |> json_response(200)

    # an unauthenticated report is refused by the labeler, not swallowed by the proxy
    assert %{"error" => "AuthMissing"} =
             conn
             |> host(:pds)
             |> post_json("/xrpc/com.atproto.moderation.createReport", %{
               "reasonType" => "com.atproto.moderation.defs#reasonSpam",
               "subject" => strong_ref
             })
             |> json_response(401)

    # -- 3. a record takedown: the PDS 404s getRecord, the AppView omits the post
    get_record =
      "/xrpc/com.atproto.repo.getRecord?repo=#{alice.did}&collection=app.bsky.feed.post&rkey=#{post.rkey}"

    assert %{"uri" => ^uri} = conn |> host(:pds) |> get(get_record) |> json_response(200)

    takedown =
      admin
      |> post_json("/xrpc/aerox.moderation.emitEvent", %{
        "action" => "takedown",
        "subject" => strong_ref,
        "comment" => "spam"
      })
      |> json_response(200)

    ref = "mod_event:#{takedown["id"]}"

    assert %{"error" => "RecordNotFound"} =
             conn |> host(:pds) |> get(get_record) |> json_response(400)

    {:ok, rec} =
      Aerox.PDS.Records.get_record(alice.did, "app.bsky.feed.post", post.rkey,
        include_taken_down: true
      )

    assert rec.takedown_ref == ref
    assert AppViewRepo.get!(S.Record, post.uri).takedown_ref == ref
    assert %{"posts" => []} = get_posts(conn, post.uri, [])

    status =
      conn
      |> host(:pds)
      |> put_req_header("authorization", admin_auth_pds())
      |> get("/xrpc/com.atproto.admin.getSubjectStatus?uri=#{URI.encode_www_form(post.uri)}")
      |> json_response(200)

    assert status["takedown"] == %{"applied" => true, "ref" => ref}

    # the event log has everything, in order, all applied
    events =
      admin
      |> get("/xrpc/aerox.moderation.queryEvents?subject=#{URI.encode_www_form(post.uri)}")
      |> json_response(200)

    assert Enum.map(events["events"], & &1["action"]) == ~w(takedown acknowledge unlabel label)
    assert Enum.all?(events["events"], &Map.has_key?(&1, "appliedAt"))

    # -- 4. restore brings the post back on both sides
    assert %{"action" => "restore"} =
             admin
             |> post_json("/xrpc/aerox.moderation.emitEvent", %{
               "action" => "restore",
               "subject" => strong_ref
             })
             |> json_response(200)

    assert %{"uri" => ^uri} = conn |> host(:pds) |> get(get_record) |> json_response(200)
    assert [%{"uri" => ^uri}] = get_posts(conn, post.uri, [])["posts"]
    assert AppViewRepo.get!(S.Record, post.uri).takedown_ref == nil
  end

  # the PDS admin API also trusts the labeler's own service JWTs (mod_service_did)
  defp admin_auth_pds do
    "Bearer " <>
      Aerox.Auth.ServiceJWT.create(
        keypair: Aerox.Labeler.Config.signing_keypair(),
        iss: Aerox.Labeler.Config.did(),
        aud: Aerox.PDS.Config.service_did(),
        lxm: "com.atproto.admin.getSubjectStatus"
      )
  end
end
