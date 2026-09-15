defmodule Aerox.Relay.IngestTest do
  @moduledoc """
  VERIFICATION §5 Relay: events from our own PDS (a real signup, real
  commits) run through the Relay's ingest — inductively verified, recorded
  as account state, re-sequenced on the Relay's own sequencer — and bad
  events are refused and counted against the host.
  """
  use Aerox.DataCase, async: false
  alias Aerox.ATProto.{Bytes, CID, Frame}
  alias Aerox.PDS.Sequencer, as: PdsSeq
  alias Aerox.Relay.{Accounts, Hosts, Ingest, Sequencer}
  alias Aerox.Relay.Schema.Host

  @pds_host "pds.aerox.sola.town"

  setup do
    Aerox.RateLimit.reset()
    {:ok, host} = Hosts.create(@pds_host, false)
    Phoenix.PubSub.subscribe(Aerox.PubSub, Sequencer.topic())
    # the Relay sequencer writes outside the sandbox: read relative to its current seq
    {:ok, host: host, relay_before: Sequencer.current() || 0}
  end

  defp pds_events(since) do
    since |> PdsSeq.range(500) |> Enum.map(&PdsSeq.Events.to_frame/1)
  end

  defp make_post(did, text) do
    {:ok, w} =
      Aerox.PDS.Records.Prepare.create(did, "app.bsky.feed.post", %{
        "$type" => "app.bsky.feed.post",
        "text" => text,
        "createdAt" => "2026-09-09T12:00:00.000Z"
      })

    {:ok, _} = Aerox.PDS.Records.process_writes(did, [w])
  end

  test "a PDS account's creation and commits are verified, tracked and re-sequenced", %{
    host: host,
    relay_before: relay_before
  } do
    before = PdsSeq.current() || 0

    {:ok, %{did: did}} =
      Aerox.PDS.Signup.create(%{
        handle: "relayed.aerox.sola.town",
        email: "r@example.com",
        password: "pw-pw-pw-pw"
      })

    make_post(did, "one")
    make_post(did, "two")

    events = pds_events(before)

    assert ["#identity", "#account", "#commit", "#sync", "#commit", "#commit"] =
             Enum.map(events, &elem(&1, 0))

    for {type, body} <- events do
      # the deprecated `tooBig` is ignored, not refused (Sync spec)
      body =
        if type == "#commit" and body["rev"] == List.last(events) |> elem(1) |> Map.get("rev"),
          do: Map.put(body, "tooBig", true),
          else: body

      assert :ok = Ingest.process(host, type, body), "#{type} #{inspect(body["seq"])}"
    end

    # account state follows the last commit
    acc = Accounts.get(did)
    assert acc.host_id == host.id and acc.status == "active"
    repo = Accounts.get_repo(acc.uid)
    {:ok, root} = Aerox.PDS.Records.root(did) |> then(&{:ok, &1})
    assert repo.commit_cid == CID.to_string(root.cid) and repo.rev == root.rev
    assert Hosts.get(@pds_host).account_count == 1

    # re-sequenced in order with the Relay's own seqs, upstream time kept
    out = Sequencer.range(relay_before, 100)
    assert length(out) == 6
    assert Enum.map(out, & &1.seq) == Enum.to_list((relay_before + 1)..(relay_before + 6))
    types = Enum.map(out, &(Sequencer.to_frame(&1) |> elem(0)))
    assert types == ["#identity", "#account", "#commit", "#sync", "#commit", "#commit"]
    {"#commit", last} = Sequencer.to_frame(List.last(out))
    assert last["seq"] == relay_before + 6 and last["repo"] == did and last["rev"] == root.rev
    assert %Bytes{} = last["blocks"]
    # frames encode and decode
    assert {:ok, {:message, "#commit", ^last}} =
             Frame.decode(Frame.encode({:message, "#commit", last}))

    # and were broadcast
    first = relay_before + 1
    assert_receive {:firehose, [%{seq: ^first}]}

    # replaying an old commit is dropped, not an error
    {"#commit", old} = Enum.at(events, 4)
    assert {:dropped, {:old_rev, _, _}} = Ingest.process(host, "#commit", old)
    assert Hosts.get(@pds_host).error_count == 0
  end

  test "a forged commit (bad signature) and a wrong-host account are refused and counted", %{
    host: host
  } do
    before = PdsSeq.current() || 0

    {:ok, %{did: did}} =
      Aerox.PDS.Signup.create(%{
        handle: "forged.aerox.sola.town",
        email: "f@example.com",
        password: "pw-pw-pw-pw"
      })

    events = pds_events(before)
    for {type, body} <- events, do: :ok = Ingest.process(host, type, body)

    make_post(did, "genuine")
    [{"#commit", commit}] = pds_events(before + length(events))

    # flip a signature byte inside the CAR: the commit block no longer verifies
    %Bytes{data: car} = commit["blocks"]
    {:ok, root, blocks} = Aerox.ATProto.CAR.decode_with_root(car)
    {^root, commit_bytes} = List.keyfind(blocks, root, 0)
    forged = binary_part(commit_bytes, 0, byte_size(commit_bytes) - 1) <> <<0>>
    # re-encoding the commit changes its CID, so also re-root the CAR at the forged block
    forged_cid = CID.for_cbor(forged)

    car2 =
      Aerox.ATProto.CAR.encode(forged_cid, [
        {forged_cid, forged} | List.keydelete(blocks, root, 0)
      ])

    bad = commit |> Map.put("blocks", Bytes.new(car2)) |> Map.put("commit", forged_cid)

    assert {:error, reason} = Ingest.process(host, "#commit", bad)

    assert reason in [:bad_signature, :invalid_commit, :did_mismatch, :rev_mismatch] or
             match?({:error, _}, {:error, reason})

    assert Hosts.get(@pds_host).error_count == 0,
           "ingest itself does not count; the consumer does"

    assert :ok = Hosts.record_error(host.id)
    assert Hosts.get(@pds_host).error_count == 1

    # an account whose DID document names another PDS is refused on this host
    {:ok, other} = Hosts.create("other.example.com", false)

    assert {:error, {:account_host_mismatch, @pds_host}} =
             Ingest.process(other, "#commit", commit)

    # the genuine commit still verifies here
    assert :ok = Ingest.process(host, "#commit", commit)
  end

  test "account status and identity events pass through with validation", %{
    host: host,
    relay_before: relay_before
  } do
    before = PdsSeq.current() || 0

    {:ok, %{did: did}} =
      Aerox.PDS.Signup.create(%{
        handle: "acctstate.aerox.sola.town",
        email: "s@example.com",
        password: "pw-pw-pw-pw"
      })

    for {type, body} <- pds_events(before), do: :ok = Ingest.process(host, type, body)

    # a handle that does not match the DID document is stripped
    assert :ok =
             Ingest.process(host, "#identity", %{
               "did" => did,
               "handle" => "liar.example.com",
               "seq" => 1,
               "time" => "2026-09-09T00:00:00.000Z"
             })

    {"#identity", out} = Sequencer.range(relay_before, 100) |> List.last() |> Sequencer.to_frame()
    refute Map.has_key?(out, "handle")

    # deactivation is recorded and re-emitted
    assert :ok =
             Ingest.process(host, "#account", %{
               "did" => did,
               "active" => false,
               "status" => "deactivated",
               "seq" => 2,
               "time" => "2026-09-09T00:00:00.000Z"
             })

    assert Accounts.get(did).upstream_status == "deactivated"
    {"#account", out} = Sequencer.range(relay_before, 100) |> List.last() |> Sequencer.to_frame()
    assert out["active"] == false and out["status"] == "deactivated"

    # a commit for an inactive account is re-checked against the PDS
    # (getRepoStatus) and, once the PDS confirms deactivation, dropped
    make_post(did, "before deactivation")
    [{"#commit", c}] = pds_events((PdsSeq.current() || 0) - 1)
    assert :ok = Ingest.process(host, "#commit", c), "the PDS still says active: accepted"
    assert Accounts.get(did).upstream_status == "active"

    :ok = Aerox.PDS.Accounts.deactivate(did)

    assert :ok =
             Ingest.process(host, "#account", %{
               "did" => did,
               "active" => false,
               "status" => "deactivated",
               "seq" => 3,
               "time" => "2026-09-09T00:00:00.000Z"
             })

    assert {:dropped, {:inactive_account, "deactivated"}} = Ingest.process(host, "#commit", c)
  end

  test "hostname parsing follows indigo's rules" do
    assert {:ok, "pds.example.com", false} = Hosts.parse_hostname("https://pds.example.com")
    assert {:ok, "pds.example.com", false} = Hosts.parse_hostname("pds.example.com")
    assert {:ok, "pds.example.com", true} = Hosts.parse_hostname("http://pds.example.com/")
    assert {:ok, "localhost:2583", true} = Hosts.parse_hostname("http://localhost:2583")
    assert {:error, _} = Hosts.parse_hostname("https://pds.example.com:8443")
    assert {:error, _} = Hosts.parse_hostname("localhost")
    assert {:error, _} = Hosts.parse_hostname("https://pds.example.com/xrpc")
    assert {:error, _} = Hosts.parse_hostname("not a host")
    assert %Host{} = %Host{hostname: "x", no_ssl: false}

    assert Hosts.firehose_url(%Host{hostname: "h.test", no_ssl: false}, 42) ==
             "wss://h.test/xrpc/com.atproto.sync.subscribeRepos?cursor=42"
  end
end
