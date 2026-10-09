defmodule AeroxWeb.PDS.FlowTest do
  @moduledoc """
  The M3 exit criterion through the HTTP surface: create an account, log in,
  write records, read them back over repo and sync, and see the events on the
  firehose handler (DEV_PLAN M3, VERIFICATION §4).
  """
  use AeroxWeb.ConnCase, async: false

  alias Aerox.ATProto.{CID, Frame, Repo}
  alias Aerox.PDS.Sequencer
  alias AeroxWeb.Sockets.Firehose
  require Ecto.Query

  @xrpc "/xrpc/"

  setup do
    Aerox.RateLimit.reset()
    :ok
  end

  defp xrpc_post(conn, method, body, token \\ nil) do
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn

    conn
    |> put_req_header("content-type", "application/json")
    |> post(@xrpc <> method, Jason.encode!(body))
  end

  defp xrpc_get(conn, method, params, token \\ nil) do
    conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn
    get(conn, @xrpc <> method, params)
  end

  defp signup(conn, handle) do
    conn =
      xrpc_post(conn, "com.atproto.server.createAccount", %{
        "handle" => handle,
        "email" => "#{handle}@example.com",
        "password" => "correct horse battery staple"
      })

    assert %{"did" => "did:plc:" <> _, "accessJwt" => _, "refreshJwt" => _} =
             body = json_response(conn, 200)

    body
  end

  test "describeServer advertises the handle domains", %{conn: conn} do
    body = conn |> xrpc_get("com.atproto.server.describeServer", %{}) |> json_response(200)
    assert ".aerox.sola.town" in body["availableUserDomains"]
    assert body["did"] == "did:web:pds.aerox.sola.town"
  end

  test "createAccount, createSession, write/read records, sync, firehose", %{conn: conn} do
    seq_before = Sequencer.current() || 0
    %{"did" => did, "accessJwt" => jwt} = signup(conn, "flow.test")

    # createSession with the handle; the session carries the did
    session =
      conn
      |> xrpc_post("com.atproto.server.createSession", %{
        "identifier" => "flow.test",
        "password" => "correct horse battery staple"
      })
      |> json_response(200)

    assert session["did"] == did
    assert session["handle"] == "flow.test"
    assert session["active"] == true

    # a wrong password is an AuthenticationRequired with the upstream message
    bad =
      conn
      |> xrpc_post("com.atproto.server.createSession", %{
        "identifier" => "flow.test",
        "password" => "nope"
      })
      |> json_response(401)

    assert bad == %{
             "error" => "AuthenticationRequired",
             "message" => "Invalid identifier or password"
           }

    # getSession with the access token
    got = conn |> xrpc_get("com.atproto.server.getSession", %{}, jwt) |> json_response(200)
    assert got["did"] == did
    assert got["email"] == "flow.test@example.com"

    # createRecord
    post = %{
      "$type" => "app.bsky.feed.post",
      "text" => "hello",
      "createdAt" => "2026-09-09T12:00:00.000Z"
    }

    created =
      conn
      |> xrpc_post(
        "com.atproto.repo.createRecord",
        %{"repo" => did, "collection" => "app.bsky.feed.post", "record" => post},
        jwt
      )
      |> json_response(200)

    assert "at://" <> _ = created["uri"]
    assert created["validationStatus"] == "valid"
    rkey = created["uri"] |> String.split("/") |> List.last()

    # getRecord (unauthenticated)
    fetched =
      conn
      |> xrpc_get("com.atproto.repo.getRecord", %{
        "repo" => did,
        "collection" => "app.bsky.feed.post",
        "rkey" => rkey
      })
      |> json_response(200)

    assert fetched["value"]["text"] == "hello"
    assert fetched["cid"] == created["cid"]

    # a record that fails lexicon validation is rejected
    invalid =
      conn
      |> xrpc_post(
        "com.atproto.repo.createRecord",
        %{
          "repo" => did,
          "collection" => "app.bsky.feed.post",
          "record" => %{"$type" => "app.bsky.feed.post", "text" => 1}
        },
        jwt
      )
      |> json_response(400)

    # upstream: InvalidRecordError becomes a plain InvalidRequest with the message
    assert invalid["error"] == "InvalidRequest"
    assert invalid["message"] =~ "Invalid app.bsky.feed.post record"

    # putRecord on the profile, then listRecords + describeRepo
    conn
    |> xrpc_post(
      "com.atproto.repo.putRecord",
      %{
        "repo" => did,
        "collection" => "app.bsky.actor.profile",
        "rkey" => "self",
        "record" => %{"$type" => "app.bsky.actor.profile", "displayName" => "Flow"}
      },
      jwt
    )
    |> json_response(200)

    listed =
      conn
      |> xrpc_get("com.atproto.repo.listRecords", %{
        "repo" => did,
        "collection" => "app.bsky.feed.post"
      })
      |> json_response(200)

    assert length(listed["records"]) == 1

    # paging with a cursor and no `reverse` (it arrives as nil) must not crash
    assert %{"records" => []} =
             conn
             |> xrpc_get("com.atproto.repo.listRecords", %{
               "repo" => did,
               "collection" => "app.bsky.feed.post",
               "cursor" => listed["cursor"]
             })
             |> json_response(200)

    described =
      conn |> xrpc_get("com.atproto.repo.describeRepo", %{"repo" => did}) |> json_response(200)

    assert Enum.sort(described["collections"]) == ["app.bsky.actor.profile", "app.bsky.feed.post"]
    assert described["handle"] == "flow.test"

    # sync.getRepo: a CAR that verifies against the signing key in the DID doc
    car_conn = xrpc_get(conn, "com.atproto.sync.getRepo", %{"did" => did})
    assert car_conn.status == 200
    assert car_conn.resp_body |> byte_size() > 100
    key = Aerox.PDS.Accounts.signing_keypair(did)

    assert {:ok, %{cid: root, records: records}} =
             Repo.verify_repo_car(car_conn.resp_body,
               did: did,
               signing_key: Aerox.ATProto.Crypto.did_key(key)
             )

    assert length(records) == 2

    latest =
      conn |> xrpc_get("com.atproto.sync.getLatestCommit", %{"did" => did}) |> json_response(200)

    assert latest["cid"] == CID.to_string(root)

    status =
      conn |> xrpc_get("com.atproto.sync.getRepoStatus", %{"did" => did}) |> json_response(200)

    assert status["active"] == true and status["rev"] == latest["rev"]

    repos = conn |> xrpc_get("com.atproto.sync.listRepos", %{}) |> json_response(200)
    assert Enum.any?(repos["repos"], &(&1["did"] == did))

    # deleteRecord
    conn
    |> xrpc_post(
      "com.atproto.repo.deleteRecord",
      %{"repo" => did, "collection" => "app.bsky.feed.post", "rkey" => rkey},
      jwt
    )
    |> json_response(200)

    assert conn
           |> xrpc_get("com.atproto.repo.getRecord", %{
             "repo" => did,
             "collection" => "app.bsky.feed.post",
             "rkey" => rkey
           })
           |> json_response(400)
           |> Map.get("error") == "RecordNotFound"

    # the firehose handler replays history from the cursor: identity,
    # account, commit (creation), then the four writes. The sequencer is
    # shared across tests, so start at the seq before signup and keep this
    # DID's events only.
    {:push, frames, state} =
      Firehose.init(%{cursor: seq_before, source: Aerox.PDS.Sequencer.Source})

    assert frames == []
    assert_receive {:backfill, ^seq_before}
    {:push, frames, _} = Firehose.handle_info({:backfill, seq_before}, state)

    types =
      for {:binary, f} <- frames,
          {:ok, {:message, t, body}} = Frame.decode(f),
          (body["did"] || body["repo"]) == did,
          do: t

    # creation: identity, account, commit, sync (upstream sequenceAccountCreation);
    # then createRecord, putRecord, deleteRecord
    assert types == [
             "#identity",
             "#account",
             "#commit",
             "#sync",
             "#commit",
             "#commit",
             "#commit"
           ]

    # a future cursor is an error frame
    {:push, {:binary, err}, %{closing: true}} =
      Firehose.init(%{
        cursor: (Sequencer.current() || 0) + 100,
        source: Aerox.PDS.Sequencer.Source
      })

    assert {:ok, {:error, "FutureCursor", _}} = Frame.decode(err)
  end

  test "auth failures: missing, malformed and wrong-scope tokens", %{conn: conn} do
    assert conn
           |> xrpc_post("com.atproto.repo.createRecord", %{
             "repo" => "did:plc:x",
             "collection" => "a.b.c",
             "record" => %{}
           })
           |> json_response(401)
           |> Map.get("error") == "AuthMissing"

    assert conn
           |> xrpc_get("com.atproto.server.getSession", %{}, "not-a-jwt")
           |> json_response(400)
           |> Map.get("error") == "InvalidToken"

    %{"refreshJwt" => refresh} = signup(conn, "scope.test")

    # a refresh token is not an access token
    assert conn
           |> xrpc_get("com.atproto.server.getSession", %{}, refresh)
           |> json_response(400)
           |> Map.get("error") == "InvalidToken"

    # but it refreshes
    refreshed =
      conn |> xrpc_post("com.atproto.server.refreshSession", %{}, refresh) |> json_response(200)

    assert refreshed["accessJwt"] != nil
  end

  test "password reset and account deletion by emailed token", %{conn: conn} do
    %{"did" => did} = signup(conn, "tokenmail.test")

    assert conn
           |> xrpc_post("com.atproto.server.requestPasswordReset", %{
             "email" => "tokenmail.test@example.com"
           })
           |> response(200)

    # the mail is queued on the PDS Oban instance and carries the token
    [job] =
      Oban.Job |> Ecto.Query.where(worker: "Aerox.PDS.Mailer.Deliver") |> Aerox.PDS.Repo.all()

    assert %{
             "purpose" => "reset_password",
             "to" => "tokenmail.test@example.com",
             "token" => token
           } = job.args

    assert :ok = Aerox.PDS.Mailer.Deliver.perform(job)

    assert conn
           |> xrpc_post("com.atproto.server.resetPassword", %{
             "token" => token,
             "password" => "a brand new password"
           })
           |> response(200)

    assert %{"accessJwt" => jwt} =
             conn
             |> xrpc_post("com.atproto.server.createSession", %{
               "identifier" => "tokenmail.test",
               "password" => "a brand new password"
             })
             |> json_response(200)

    assert conn |> xrpc_post("com.atproto.server.requestAccountDelete", %{}, jwt) |> response(200)

    delete_token =
      Oban.Job
      |> Ecto.Query.where(worker: "Aerox.PDS.Mailer.Deliver")
      |> Aerox.PDS.Repo.all()
      |> Enum.find_value(&(&1.args["purpose"] == "delete_account" && &1.args["token"]))

    assert conn
           |> xrpc_post("com.atproto.server.deleteAccount", %{
             "did" => did,
             "password" => "a brand new password",
             "token" => delete_token
           })
           |> response(200)
  end

  test "preferences round trip and unknown method", %{conn: conn} do
    %{"accessJwt" => jwt} = signup(conn, "prefs.test")
    prefs = [%{"$type" => "app.bsky.actor.defs#adultContentPref", "enabled" => true}]

    assert conn
           |> xrpc_post("app.bsky.actor.putPreferences", %{"preferences" => prefs}, jwt)
           |> response(200)

    assert conn |> xrpc_get("app.bsky.actor.getPreferences", %{}, jwt) |> json_response(200) ==
             %{"preferences" => prefs}

    assert conn |> get("/xrpc/com.example.nope") |> json_response(501) |> Map.get("error") ==
             "MethodNotImplemented"
  end
end
