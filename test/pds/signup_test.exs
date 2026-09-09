defmodule Aerox.PDS.SignupTest do
  @moduledoc """
  DESIGN §18.3: the signup saga against the in-process PLC directory (the
  HTTP client runs through the Phoenix endpoint). Also the PLC signing call
  site's audit and count invariant (§14.2).
  """
  use Aerox.DataCase, async: false, repos: [Aerox.PDS.Repo, Aerox.PLC.Repo]
  alias Aerox.PDS.{Accounts, PlcOps, Sequencer, Signup}

  @moduletag :service

  setup do
    Phoenix.PubSub.subscribe(Aerox.PubSub, Sequencer.topic())
    :ok
  end

  test "create: account, repo, PLC document, activation events, session" do
    n = System.unique_integer([:positive])

    assert {:ok, result} =
             Signup.create(%{
               handle: "signup#{n}.test",
               email: "signup#{n}@example.com",
               password: "pw#{n}"
             })

    assert String.starts_with?(result.did, "did:plc:")
    assert %{"id" => did, "alsoKnownAs" => [aka]} = result.did_doc
    assert did == result.did and aka == "at://signup#{n}.test"

    assert %{deactivated_at: nil} = Accounts.get_account(result.did)
    assert %{cid: _, rev: _} = Aerox.PDS.Records.root(result.did)
    assert {:ok, %{"sub" => ^did}} = Aerox.PDS.Sessions.verify(result.access_jwt, "at+jwt")

    # the directory has exactly one op, signed by the instance rotation key, and it is audited
    assert {:ok, [%{"operation" => op}]} = PlcOps.audit_log(did)
    assert op["rotationKeys"] == [PlcOps.rotation_did_key()]
    assert op["services"]["atproto_pds"]["endpoint"] == "https://pds.aerox.sola.town"
    assert [%{purpose: "signup"}] = Aerox.PDS.Repo.all(Aerox.PDS.Schema.PlcOpAudit)

    # identity, active, commit, sync — in that order
    assert_receive {:firehose, rows}, 2_000
    assert Enum.map(rows, & &1.event_type) == ["identity", "account", "append", "sync"]

    # a second signup with the same handle is refused before anything is written
    assert {:error, {"HandleNotAvailable", _}} = Signup.create(%{handle: "signup#{n}.test"})
    assert {:error, {"InvalidHandle", _}} = Signup.create(%{handle: "x.test"})

    assert {:error, {"HandleNotAvailable", "Reserved handle"}} =
             Signup.create(%{handle: "admin.test"})

    assert {:error, {"UnsupportedDomain", _}} = Signup.create(%{handle: "alice.example.org"})

    assert {:error, {"InvalidRequest", _}} =
             Signup.create(%{handle: "bob#{n}.test", email: "not-an-email", password: "x"})
  end

  test "handle update goes through the directory and emits #identity" do
    n = System.unique_integer([:positive])
    {:ok, %{did: did}} = Signup.create(%{handle: "before#{n}.test"})
    assert_receive {:firehose, _}, 2_000
    assert {:ok, op} = PlcOps.update_handle(did, "after#{n}.test", did)
    expected = "at://after#{n}.test"
    assert op["alsoKnownAs"] == [expected]
    assert {:ok, %{"alsoKnownAs" => [^expected]}} = PlcOps.resolve(did)
    assert {:ok, [_, _]} = PlcOps.audit_log(did)

    assert [_, %{purpose: "update_handle"}] =
             Aerox.PDS.Repo.all(Aerox.PDS.Schema.PlcOpAudit) |> Enum.sort_by(& &1.id)
  end

  test "tombstone and the count invariant" do
    n = System.unique_integer([:positive])
    {:ok, %{did: did}} = Signup.create(%{handle: "tomb#{n}.test"})
    assert_receive {:firehose, _}, 2_000
    assert :ok = PlcOps.tombstone(did)
    assert {:error, :not_found} = PlcOps.resolve(did)
    assert {:error, :tombstoned} = PlcOps.update_handle(did, "x#{n}.test", did)
  end

  test "resume completes an interrupted signup; orphans are reaped" do
    n = System.unique_integer([:positive])
    kp = Aerox.ATProto.Crypto.generate(:k256)

    did =
      "did:plc:" <> (:crypto.strong_rand_bytes(15) |> Base.encode32(case: :lower, padding: false))

    {:ok, _} =
      Accounts.register(%{
        did: did,
        handle: "orphan#{n}.test",
        signing_key: kp.private,
        deactivated: true
      })

    {:ok, _} = Aerox.PDS.Records.create_repo(did, kp)
    assert {:ok, :orphan} = Signup.resume(did)

    Aerox.PDS.Repo.update_all(Aerox.PDS.Schema.Actor,
      set: [delete_after: DateTime.add(DateTime.utc_now(), -1)]
    )

    assert [^did] = Signup.reap_orphans()
    assert nil == Accounts.get_account(did, include_deactivated: true)
  end
end
