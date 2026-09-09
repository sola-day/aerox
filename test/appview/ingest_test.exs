defmodule Aerox.AppView.IngestTest do
  @moduledoc """
  VERIFICATION §5 AppView: the Broadway ingest against a fake Relay served
  by Bandit in-process — connects with the persisted cursor (0 at first),
  indexes a real signup's events, persists the cursor once the events are
  acked, and resumes from it.
  """
  use Aerox.DataCase, async: false
  alias Aerox.ATProto.Frame
  alias Aerox.PDS.Sequencer, as: PdsSeq
  alias Aerox.AppView.Ingest.Cursor
  alias Aerox.AppView.Repo
  alias Aerox.AppView.Schema, as: S

  defmodule FakeRelay do
    @moduledoc false
    @behaviour WebSock

    def init(%{frames: frames, test: test}) do
      send(test, {:connected, self()})
      {:push, Enum.map(frames, &{:binary, &1}), %{test: test}}
    end

    def handle_in(_, state), do: {:ok, state}
    def handle_info(:close, state), do: {:stop, :normal, {1000, "bye"}, state}
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
      after_seq = if cursor, do: String.to_integer(cursor), else: 0

      frames =
        Enum.filter(opts[:frames].(), fn bin ->
          {:ok, {:message, _, %{"seq" => seq}}} = Frame.decode(bin)
          seq > after_seq
        end)

      WebSockAdapter.upgrade(conn, FakeRelay, %{frames: frames, test: opts[:test]}, [])
    end

    def call(conn, _), do: Plug.Conn.send_resp(conn, 404, "")
  end

  defp wait_until(fun, tries \\ 100) do
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

  test "indexes a relay's replay and persists the acked cursor", _ do
    Aerox.RateLimit.reset()
    test = self()
    before = PdsSeq.current() || 0

    {:ok, %{did: did}} =
      Aerox.PDS.Signup.create(%{
        handle: "ingested.aerox.sola.town",
        email: "i@example.com",
        password: "pw-pw-pw-pw"
      })

    frames =
      for row <- PdsSeq.range(before, 100) do
        {t, body} = PdsSeq.Events.to_frame(row)
        Frame.encode({:message, t, body})
      end

    agent = start_supervised!({Agent, fn -> frames end})

    pid =
      start_supervised!(
        {Bandit,
         plug: {FakePlug, [test: test, frames: fn -> Agent.get(agent, & &1) end]},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(pid)
    url = "ws://localhost:#{port}"
    service = "localhost"

    # the pipeline runs outside the sandbox owner: share the connection
    Ecto.Adapters.SQL.Sandbox.mode(Aerox.AppView.Repo, {:shared, self()})
    Ecto.Adapters.SQL.Sandbox.mode(Aerox.PDS.Repo, {:shared, self()})
    Ecto.Adapters.SQL.Sandbox.mode(Aerox.PLC.Repo, {:shared, self()})

    ingest =
      start_supervised!(
        {Aerox.AppView.Ingest, url: url, name: :ingest_under_test, concurrency: 2}
      )

    assert_receive {:cursor, "0"}, 2_000
    assert_receive {:connected, ws}, 2_000

    wait_until(fn -> Repo.get(S.Actor, did) != nil and Repo.get(S.ActorSync, did) != nil end)
    assert Repo.get!(S.Actor, did).handle == "ingested.aerox.sola.town"

    last_seq = before + 4
    wait_until(fn -> Cursor.get(service) == last_seq end)

    # the relay drops the connection: the pipeline reconnects from the persisted cursor
    send(ws, :close)
    assert_receive {:cursor, cursor}, 10_000
    assert cursor == to_string(last_seq)
    stop_supervised!(Aerox.AppView.Ingest)
    _ = ingest
  end
end
