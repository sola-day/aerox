Code.require_file("helpers.exs", __DIR__)

defmodule Aerox.Labeler.AppViewLabelsTest do
  @moduledoc """
  DESIGN §15.6 / §17.1 end to end over a socket: the real `subscribeLabels`
  server (`AeroxWeb.Sockets.Firehose` over `Aerox.Labeler.Labels.Source`)
  served by Bandit in-process, consumed by `Aerox.AppView.Labels.Consumer`
  — backfill from the persisted cursor, live labels through the sequencer's
  fan-out, negation, and cursor persistence.
  """
  use Aerox.DataCase, async: false
  alias Aerox.AppView.Labels, as: AppViewLabels
  alias Aerox.AppView.Repo, as: AppViewRepo
  alias Aerox.AppView.Schema, as: S
  alias Aerox.Labeler.Labels
  import Aerox.LabelerTestHelpers

  defmodule LabelerPlug do
    @moduledoc "The labeler host's subscribeLabels route, and nothing else."
    @behaviour Plug
    def init(opts), do: opts

    def call(%{request_path: "/xrpc/com.atproto.label.subscribeLabels"} = conn, opts) do
      conn = Plug.Conn.fetch_query_params(conn)
      send(opts[:test], {:cursor, conn.query_params["cursor"]})
      AeroxWeb.Sockets.Firehose.Plug.call(conn, Aerox.Labeler.Labels.Source)
    end

    def call(conn, _), do: Plug.Conn.send_resp(conn, 404, "")
  end

  defp wait_until(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met")
      true -> Process.sleep(50) && wait_until(fun, tries - 1)
    end
  end

  @post "at://did:plc:aaaaaaaaaaaaaaaaaaaaaaaa/app.bsky.feed.post/3kabc"

  test "apply upserts by (src, uri, cid, val); a negation replaces the row", _ do
    l = %{
      "src" => "did:plc:x",
      "uri" => @post,
      "cid" => "",
      "val" => "spam",
      "cts" => "2026-01-01T00:00:00.000Z",
      "sig" => %{"$bytes" => Base.encode64("sig", padding: false)}
    }

    assert AppViewLabels.apply([l, Map.put(l, "val", "rude")]) == 2

    assert AppViewLabels.apply(
             Map.merge(l, %{"neg" => true, "cts" => "2026-01-02T00:00:00.000Z"})
           ) == 1

    rows = AppViewRepo.all(S.Label) |> Enum.sort_by(& &1.val)
    assert [%{val: "rude", neg: false}, %{val: "spam", neg: true, sig: "sig"}] = rows
    # malformed labels are dropped, not raised
    assert AppViewLabels.apply([%{"src" => "x"}, Map.put(l, "cts", "nope")]) == 0
  end

  test "the consumer backfills from its cursor, follows live labels and persists the cursor", _ do
    labeler = configure_unit_labeler!()
    test = self()

    # labels before the consumer connects: backfilled
    {:ok, l1} = Labels.create(%{uri: @post, val: "spam"})
    # a label the consumer must ignore: another labeler's
    other = %{
      "src" => "did:plc:other",
      "uri" => @post,
      "val" => "spam",
      "cts" => "2026-01-01T00:00:00.000Z"
    }

    {:ok, _} = Aerox.Labeler.Sequencer.sequence_labels("did:plc:other", [other])

    pid =
      start_supervised!(
        {Bandit, plug: {LabelerPlug, [test: test]}, scheme: :http, ip: {127, 0, 0, 1}, port: 0}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)

    # the socket and the consumer run outside the test process: share the sandbox
    Ecto.Adapters.SQL.Sandbox.mode(Aerox.Labeler.Repo, {:shared, self()})
    Ecto.Adapters.SQL.Sandbox.mode(Aerox.AppView.Repo, {:shared, self()})

    # resume from just before l1, as a restarted AppView would
    AppViewLabels.put_cursor(labeler.did, l1.seq - 1)

    consumer =
      start_supervised!(
        {Aerox.AppView.Labels.Consumer,
         did: labeler.did, url: "ws://localhost:#{port}", persist_every: 100}
      )

    assert_receive {:cursor, cursor}, 2_000
    assert cursor == Integer.to_string(l1.seq - 1)

    wait_until(fn ->
      AppViewRepo.get_by(S.Label, uri: @post, val: "spam", src: labeler.did) != nil
    end)

    assert AppViewRepo.aggregate(S.Label, :count) == 1

    # live: created after the connection, fanned out through the sequencer
    {:ok, l2} = Labels.create(%{uri: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb", val: "rude"})

    wait_until(fn ->
      AppViewRepo.get_by(S.Label, uri: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb") != nil
    end)

    {:ok, l3} = Labels.negate(@post, nil, "spam")
    wait_until(fn -> AppViewRepo.get_by(S.Label, uri: @post, val: "spam").neg == true end)
    assert l3.seq > l2.seq

    wait_until(fn -> AppViewLabels.cursor(labeler.did) == l3.seq end)
    assert AppViewRepo.aggregate(S.Label, :count) == 2

    # the consumer supervisor starts one consumer per configured labeler
    stop_supervised!(Aerox.AppView.Labels.Consumer)
    _ = consumer

    sup =
      start_supervised!(
        {Aerox.AppView.Labels, labelers: [%{did: labeler.did, url: "ws://localhost:#{port}"}]}
      )

    assert [{{:labeler, _}, _, :worker, _}] = Supervisor.which_children(sup)
    assert_receive {:cursor, cursor}, 2_000
    assert cursor == Integer.to_string(l3.seq)
  end
end
