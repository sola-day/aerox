defmodule Aerox.Relay.ConsumerTest do
  @moduledoc """
  VERIFICATION §5 Relay / §7.3 "Crawling": the per-host consumer against a
  fake PDS firehose served by Bandit in-process — connects with the host's
  cursor, ingests scripted frames (a real signup's events from our PDS
  sequencer), persists the cursor, and reconnects with the persisted cursor
  when the host drops the connection.
  """
  use Aerox.DataCase, async: false
  alias Aerox.ATProto.Frame
  alias Aerox.PDS.Sequencer, as: PdsSeq
  alias Aerox.Relay.{Accounts, Consumer, Hosts, Sequencer}

  defmodule FakeHost do
    @moduledoc false
    @behaviour WebSock

    def init(%{frames: frames, test: test}) do
      send(test, {:connected, self()})
      {:push, Enum.map(frames, &{:binary, &1}), %{test: test}}
    end

    def handle_in(_, state), do: {:ok, state}
    def handle_info(:close, state), do: {:stop, :normal, {1000, "bye"}, state}
    def handle_info({:push, bin}, state), do: {:push, {:binary, bin}, state}
    def handle_info(_, state), do: {:ok, state}
    def terminate(_, _), do: :ok
  end

  defmodule FakePlug do
    @moduledoc false
    @behaviour Plug
    def init(opts), do: opts

    def call(%{request_path: "/xrpc/com.atproto.sync.subscribeRepos"} = conn, opts) do
      conn = Plug.Conn.fetch_query_params(conn)
      cursor = conn.query_params["cursor"]
      send(opts[:test], {:cursor, cursor})
      # a real host replays only events after the cursor
      after_seq = if cursor, do: String.to_integer(cursor), else: 0

      frames =
        Enum.filter(opts[:frames].(), fn bin ->
          {:ok, {:message, _, %{"seq" => seq}}} = Aerox.ATProto.Frame.decode(bin)
          seq > after_seq
        end)

      WebSockAdapter.upgrade(conn, FakeHost, %{frames: frames, test: opts[:test]}, [])
    end

    def call(conn, _), do: Plug.Conn.send_resp(conn, 404, "")
  end

  setup do
    Aerox.RateLimit.reset()
    # the fake host is localhost while the DID documents name pds.aerox.sola.town
    original = Application.get_env(:aerox, Aerox.Relay)

    Application.put_env(
      :aerox,
      Aerox.Relay,
      Keyword.put(original, :skip_account_host_check, true)
    )

    on_exit(fn -> Application.put_env(:aerox, Aerox.Relay, original) end)
    test = self()
    before = PdsSeq.current() || 0

    {:ok, %{did: did}} =
      Aerox.PDS.Signup.create(%{
        handle: "crawled.aerox.sola.town",
        email: "c@example.com",
        password: "pw-pw-pw-pw"
      })

    frames =
      for row <- PdsSeq.range(before, 100) do
        {t, body} = PdsSeq.Events.to_frame(row)
        Frame.encode({:message, t, body})
      end

    frames_agent = start_supervised!({Agent, fn -> frames end})

    pid =
      start_supervised!(
        {Bandit,
         plug: {FakePlug, [test: test, frames: fn -> Agent.get(frames_agent, & &1) end]},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)

    {:ok,
     did: did,
     port: port,
     frames_agent: frames_agent,
     relay_before: Sequencer.current() || 0,
     first_seq: before + 1}
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition not met")

      true ->
        Process.sleep(50)
        wait_until(fun, tries - 1)
    end
  end

  test "connects, ingests, persists the cursor, and resumes from it after the host closes", ctx do
    {:ok, host} = Hosts.create("localhost:#{ctx.port}", true)
    # allow the sandbox connection to the consumer process
    consumer = start_supervised!({Consumer, host})
    Ecto.Adapters.SQL.Sandbox.allow(Aerox.Relay.Repo, self(), consumer)
    Ecto.Adapters.SQL.Sandbox.allow(Aerox.PDS.Repo, self(), consumer)

    assert_receive {:cursor, nil}, 2_000
    assert_receive {:connected, ws}, 2_000

    # identity, account, commit, sync → four re-sequenced events
    wait_until(fn -> length(Sequencer.range(ctx.relay_before, 100)) >= 4 end)

    types =
      for row <- Sequencer.range(ctx.relay_before, 100), do: Sequencer.to_frame(row) |> elem(0)

    assert types == ["#identity", "#account", "#commit", "#sync"]
    assert Accounts.get(ctx.did).host_id == host.id

    # the upstream cursor is persisted (last upstream seq) and the host is active
    last_seq = ctx.first_seq + 3
    wait_until(fn -> Hosts.get(host.hostname).last_seq == last_seq end)
    assert Hosts.get(host.hostname).status == "active"
    assert %{cursor: ^last_seq, connected?: true} = Consumer.status(host.hostname)

    # the host drops the connection: the consumer reconnects with cursor=<last seq>
    send(ws, :close)
    assert_receive {:cursor, cursor}, 5_000
    assert cursor == to_string(last_seq)
    assert_receive {:connected, _}, 2_000

    # nothing after the cursor: nothing is re-emitted
    Process.sleep(300)
    assert length(Sequencer.range(ctx.relay_before, 100)) == 4
    assert %{connected?: true, backoff: 0} = Consumer.status(host.hostname)
  end
end
