Code.require_file("../../labeler/helpers.exs", __DIR__)

defmodule AeroxWeb.Labeler.HttpTest do
  @moduledoc """
  The Labeler's HTTP surface on its own host (AeroxWeb.Dispatch): the DID
  document, `queryLabels`, `createReport` with a service JWT from the
  reporter's PDS, and the `aerox.moderation.*` admin API applying `label`
  and `takedown` through the Actions log (DESIGN §17).
  """
  use AeroxWeb.ConnCase, async: false
  alias Aerox.ATProto.Lexicon
  alias Aerox.Labeler.{Config, Labels}
  import Aerox.LabelerTestHelpers

  setup %{conn: conn} do
    labeler = ensure_labeler!()

    {:ok, reporter} =
      Aerox.PDS.Signup.create(%{
        handle: "reporter.aerox.sola.town",
        email: "r@example.com",
        password: "pw-pw-pw-pw"
      })

    {:ok, conn: %{conn | host: Config.hostname()}, labeler: labeler, reporter: reporter}
  end

  defp validate!(nsid, body) do
    # JSON → data model first: `sig` is a `$bytes` value
    value = Aerox.ATProto.Data.from_json!(body)

    assert {:ok, _} = Lexicon.validate_output(Lexicon.default_registry(), nsid, value),
           "#{nsid} output does not validate: #{inspect(body)}"

    body
  end

  defp post_json(conn, path, body),
    do:
      conn
      |> put_req_header("content-type", "application/json")
      |> post(path, Jason.encode!(body))

  @post "at://did:plc:aaaaaaaaaaaaaaaaaaaaaaaa/app.bsky.feed.post/3kabc"

  test "the labeler account carries the service record and the DID document names the labeler",
       ctx do
    did = ctx.labeler.did
    assert did == Config.did()
    assert conn_health(ctx.conn)

    # the account's DID document (through the PLC) has the labeler service and key
    {:ok, doc} = Aerox.Identity.resolve_did(Aerox.Labeler.Identity, did, force: true)
    assert Aerox.ATProto.Identity.labeler_endpoint(doc) == Config.public_url()
    {:ok, label_key} = Aerox.ATProto.Identity.did_key_for(doc, "atproto_label")
    assert label_key == Aerox.ATProto.Crypto.did_key(Config.signing_keypair())
    assert Aerox.ATProto.Identity.signing_did_key(doc) == {:ok, label_key}

    {:ok, %{value: record}} =
      Aerox.PDS.Records.get_record(did, "app.bsky.labeler.service", "self")

    assert record["policies"]["labelValues"] == ["spam", "rude", "!hide"]

    assert {:ok, _} =
             Lexicon.validate_record(
               Lexicon.default_registry(),
               "app.bsky.labeler.service",
               record
             )

    # setup is idempotent: a second run changes nothing
    assert %{did: ^did, created?: false} =
             Aerox.Labeler.Setup.ensure_account!(handle: handle(), password: "labeler-pw-pw")
  end

  defp conn_health(conn), do: conn |> get("/_health") |> json_response(200) == %{"status" => "ok"}

  test "queryLabels serves signed labels with a cursor and validates its params", ctx do
    {:ok, _} = Labels.create(%{uri: @post, val: "spam"})
    {:ok, _} = Labels.create(%{uri: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb", val: "rude"})

    body =
      ctx.conn
      |> get("/xrpc/com.atproto.label.queryLabels?uriPatterns=#{URI.encode_www_form(@post)}")
      |> json_response(200)
      |> then(&validate!("com.atproto.label.queryLabels", &1))

    assert [
             %{
               "src" => src,
               "uri" => @post,
               "val" => "spam",
               "ver" => 1,
               "sig" => %{"$bytes" => _},
               "cts" => _
             }
           ] = body["labels"]

    assert src == ctx.labeler.did
    assert is_binary(body["cursor"])

    body =
      ctx.conn
      |> get("/xrpc/com.atproto.label.queryLabels?uriPatterns=*&limit=1")
      |> json_response(200)

    assert [%{"uri" => @post}] = body["labels"]

    body =
      ctx.conn
      |> get("/xrpc/com.atproto.label.queryLabels?uriPatterns=*&limit=1&cursor=#{body["cursor"]}")
      |> json_response(200)

    assert [%{"uri" => "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb"}] = body["labels"]

    assert %{"error" => "InvalidRequest"} =
             ctx.conn |> get("/xrpc/com.atproto.label.queryLabels") |> json_response(400)

    assert %{"error" => "InvalidRequest", "message" => "invalid pattern: " <> _} =
             ctx.conn
             |> get("/xrpc/com.atproto.label.queryLabels?uriPatterns=at://*/x")
             |> json_response(400)
  end

  test "createReport needs a service JWT for the reporter (either audience) and stores the report",
       ctx do
    nsid = "com.atproto.moderation.createReport"

    input = %{
      "reasonType" => "com.atproto.moderation.defs#reasonSpam",
      "reason" => "so spammy",
      "subject" => %{
        "$type" => "com.atproto.repo.strongRef",
        "uri" => @post,
        "cid" => "bafyreidfayvfuwqa7qlnopdjiqrxzs6blmoeu4rujcjtnci5beludirz2a"
      }
    }

    assert %{"error" => "AuthMissing"} =
             post_json(ctx.conn, "/xrpc/#{nsid}", input) |> json_response(401)

    body =
      ctx.conn
      |> put_req_header("authorization", "Bearer " <> service_jwt(ctx.reporter.did, nsid))
      |> post_json("/xrpc/#{nsid}", input)
      |> json_response(200)
      |> then(&validate!(nsid, &1))

    assert %{
             "id" => id,
             "reportedBy" => reporter,
             "reasonType" => "com.atproto.moderation.defs#reasonSpam",
             "reason" => "so spammy",
             "subject" => %{"uri" => @post}
           } = body

    assert reporter == ctx.reporter.did

    # did:web:<labeler host> is accepted as the audience too
    body =
      ctx.conn
      |> put_req_header(
        "authorization",
        "Bearer " <> service_jwt(ctx.reporter.did, nsid, "did:web:" <> Config.hostname())
      )
      |> post_json("/xrpc/#{nsid}", %{
        "reasonType" => "com.atproto.moderation.defs#reasonRude",
        "subject" => %{
          "$type" => "com.atproto.admin.defs#repoRef",
          "did" => "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa"
        }
      })
      |> json_response(200)

    assert body["id"] > id

    # wrong audience / wrong method are refused
    assert %{"error" => "BadJwtAudience"} =
             ctx.conn
             |> put_req_header(
               "authorization",
               "Bearer " <> service_jwt(ctx.reporter.did, nsid, "did:web:other.example")
             )
             |> post_json("/xrpc/#{nsid}", input)
             |> json_response(401)

    assert %{"error" => "BadJwtLexiconMethod"} =
             ctx.conn
             |> put_req_header(
               "authorization",
               "Bearer " <> service_jwt(ctx.reporter.did, "com.atproto.label.queryLabels")
             )
             |> post_json("/xrpc/#{nsid}", input)
             |> json_response(401)

    # invalid input is a lexicon error
    assert %{"error" => "InvalidRequest"} =
             ctx.conn
             |> put_req_header("authorization", "Bearer " <> service_jwt(ctx.reporter.did, nsid))
             |> post_json("/xrpc/#{nsid}", %{"subject" => input["subject"]})
             |> json_response(400)

    reports =
      ctx.conn
      |> put_req_header("authorization", admin_auth())
      |> get("/xrpc/aerox.moderation.queryReports")
      |> json_response(200)
      |> then(&validate!("aerox.moderation.queryReports", &1))

    assert length(reports["reports"]) == 2

    reports =
      ctx.conn
      |> put_req_header("authorization", admin_auth())
      |> get("/xrpc/aerox.moderation.queryReports?subject=#{URI.encode_www_form(@post)}")
      |> json_response(200)

    assert [%{"id" => ^id}] = reports["reports"]
  end

  test "the admin API is HTTP Basic only; emitEvent applies label and takedown and the log is queryable",
       ctx do
    assert %{"error" => "AuthenticationRequired"} =
             ctx.conn |> get("/xrpc/aerox.moderation.queryEvents") |> json_response(401)

    assert %{"error" => "AuthenticationRequired"} =
             ctx.conn
             |> put_req_header("authorization", "Basic " <> Base.encode64("admin:wrong"))
             |> get("/xrpc/aerox.moderation.queryEvents")
             |> json_response(401)

    # a service JWT is not admin either
    assert %{"error" => "AuthenticationRequired"} =
             ctx.conn
             |> put_req_header(
               "authorization",
               "Bearer " <> service_jwt(ctx.reporter.did, "aerox.moderation.queryEvents")
             )
             |> get("/xrpc/aerox.moderation.queryEvents")
             |> json_response(401)

    admin = put_req_header(ctx.conn, "authorization", admin_auth())

    record = %{
      "$type" => "com.atproto.repo.strongRef",
      "uri" => "at://#{ctx.reporter.did}/app.bsky.feed.post/3kzzz",
      "cid" => "bafyreidfayvfuwqa7qlnopdjiqrxzs6blmoeu4rujcjtnci5beludirz2a"
    }

    event =
      admin
      |> post_json("/xrpc/aerox.moderation.emitEvent", %{
        "action" => "label",
        "subject" => record,
        "createdBy" => "did:plc:moderator",
        "meta" => %{"val" => "rude"},
        "comment" => "rude post"
      })
      |> json_response(200)
      |> then(&validate!("aerox.moderation.emitEvent", &1))

    assert %{
             "action" => "label",
             "subject" => ^record,
             "createdBy" => "did:plc:moderator",
             "appliedAt" => _,
             "meta" => %{"val" => "rude"}
           } = event

    assert Labels.applied?(record["uri"], "rude")

    labels =
      ctx.conn
      |> get(
        "/xrpc/com.atproto.label.queryLabels?uriPatterns=#{URI.encode_www_form(record["uri"])}"
      )
      |> json_response(200)

    assert [%{"val" => "rude"}] = labels["labels"]

    # takedown of the reporter's account: the PDS admin API is called with the labeler's service JWT
    takedown =
      admin
      |> post_json("/xrpc/aerox.moderation.emitEvent", %{
        "action" => "takedown",
        "subject" => %{"$type" => "com.atproto.admin.defs#repoRef", "did" => ctx.reporter.did}
      })
      |> json_response(200)

    assert takedown["action"] == "takedown" and takedown["createdBy"] == "admin"
    account = Aerox.PDS.Accounts.get_account(ctx.reporter.did, include_taken_down: true)
    assert account.takedown_ref == "mod_event:#{takedown["id"]}"
    assert Aerox.PDS.Accounts.get_account(ctx.reporter.did) == nil

    restore =
      admin
      |> post_json("/xrpc/aerox.moderation.emitEvent", %{
        "action" => "restore",
        "subject" => %{"$type" => "com.atproto.admin.defs#repoRef", "did" => ctx.reporter.did}
      })
      |> json_response(200)

    assert restore["action"] == "restore"
    assert Aerox.PDS.Accounts.get_account(ctx.reporter.did).takedown_ref == nil

    # bad input
    assert %{"error" => "InvalidRequest"} =
             admin
             |> post_json("/xrpc/aerox.moderation.emitEvent", %{
               "action" => "label",
               "subject" => record
             })
             |> json_response(400)

    assert %{"error" => "InvalidRequest"} =
             admin
             |> post_json("/xrpc/aerox.moderation.emitEvent", %{
               "action" => "ban",
               "subject" => record
             })
             |> json_response(400)

    events =
      admin
      |> get("/xrpc/aerox.moderation.queryEvents")
      |> json_response(200)
      |> then(&validate!("aerox.moderation.queryEvents", &1))

    assert Enum.map(events["events"], & &1["action"]) == ~w(restore takedown label)

    events =
      admin
      |> get("/xrpc/aerox.moderation.queryEvents?subject=#{ctx.reporter.did}&limit=1")
      |> json_response(200)

    assert [%{"action" => "restore"}] = events["events"]
    assert is_binary(events["cursor"])

    events =
      admin
      |> get(
        "/xrpc/aerox.moderation.queryEvents?subject=#{ctx.reporter.did}&limit=1&cursor=#{events["cursor"]}"
      )
      |> json_response(200)

    assert [%{"action" => "takedown"}] = events["events"]
  end
end
