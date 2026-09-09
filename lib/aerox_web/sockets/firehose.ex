defmodule AeroxWeb.Sockets.Firehose do
  @moduledoc """
  `com.atproto.sync.subscribeRepos` (DESIGN §5.1, §21.4): a raw WebSocket
  carrying DAG-CBOR frames, not a Phoenix Channel. Upgrade with
  `WebSockAdapter`; this module is the WebSock handler.

  Cursor semantics follow upstream: a cursor past the current seq is a
  `FutureCursor` error frame and a close; a cursor older than the backfill
  window emits an `#info OutdatedCursor` and resumes from the window's
  start; otherwise `repo_seq` is replayed from the cursor (pages of 500),
  and live events arrive over PubSub, deduplicated by seq so the cutover
  from backfill to live has no gap and no duplicate.

  Slow consumers: when the process's mailbox exceeds the threshold the
  socket closes with `ConsumerTooSlow`; the client reconnects with its
  cursor and replays from `repo_seq`. BEAM mailboxes are unbounded, so a
  slow consumer must never be allowed to grow one (DESIGN §21.4).
  """
  @behaviour WebSock
  alias Aerox.ATProto.Frame
  alias Aerox.PDS.Sequencer
  alias Aerox.PDS.Sequencer.Events

  @page 500
  @max_queue 5_000
  @nsid "com.atproto.sync.subscribeRepos"

  @impl true
  def init(%{cursor: cursor} = opts) do
    backfill_window = Map.get(opts, :backfill_window_ms, 3 * 24 * 3600 * 1000)
    Phoenix.PubSub.subscribe(Aerox.PubSub, Sequencer.topic())
    state = %{last_seen: nil, pending: []}

    case cursor do
      nil ->
        {:ok, state}

      cursor ->
        current = Sequencer.current() || 0

        cond do
          cursor > current ->
            {:push, {:binary, Frame.encode({:error, "FutureCursor", "Cursor in the future."})},
             Map.put(state, :closing, true)}

          true ->
            outdated? =
              case Sequencer.next_after(cursor) do
                %{sequenced_at: at} ->
                  DateTime.diff(DateTime.utc_now(), at, :millisecond) > backfill_window

                nil ->
                  false
              end

            {frames, start} =
              if outdated? do
                start_row =
                  Sequencer.earliest_after_time(
                    DateTime.add(DateTime.utc_now(), -backfill_window, :millisecond)
                  )

                info =
                  Frame.encode(
                    {:message, "#info",
                     %{
                       "name" => "OutdatedCursor",
                       "message" => "Requested cursor exceeded limit. Possibly missing events"
                     }}
                  )

                {[info], (start_row && start_row.seq - 1) || cursor}
              else
                {[], cursor}
              end

            send(self(), {:backfill, start})
            {:push, Enum.map(frames, &{:binary, &1}), state}
        end
    end
  end

  @impl true
  def handle_in({_data, _opts}, state), do: {:ok, state}

  @impl true
  def handle_info({:backfill, after_seq}, state) do
    rows = Sequencer.range(after_seq, @page)
    frames = rows |> Enum.map(&encode_row/1) |> Enum.map(&{:binary, &1})
    last = List.last(rows)

    state = if last, do: %{state | last_seen: last.seq}, else: state
    if length(rows) == @page, do: send(self(), {:backfill, last.seq})
    {:push, frames, state}
  end

  def handle_info({:firehose, rows}, state) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, n} when n > @max_queue ->
        {:stop, :normal, {1008, "ConsumerTooSlow"}, state}

      _ ->
        fresh = Enum.filter(rows, &(is_nil(state.last_seen) or &1.seq > state.last_seen))
        frames = fresh |> Enum.map(&encode_row/1) |> Enum.map(&{:binary, &1})
        last = List.last(fresh)
        state = if last, do: %{state | last_seen: last.seq}, else: state
        {:push, frames, state}
    end
  end

  def handle_info(_, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  defp encode_row(row) do
    {t, body} = Events.to_frame(row)
    Frame.encode({:message, t, body})
  end

  def nsid, do: @nsid
end

defmodule AeroxWeb.Sockets.Firehose.Plug do
  @moduledoc "Router entry for the firehose: validates the cursor, then hands the connection to `AeroxWeb.Sockets.Firehose`."
  @behaviour Plug
  @impl true
  def init(opts), do: opts
  @impl true
  def call(conn, _opts), do: upgrade(conn, [])

  @doc "The Plug that upgrades `/xrpc/com.atproto.sync.subscribeRepos`."
  def upgrade(conn, _opts) do
    cursor =
      case conn.query_params["cursor"] do
        nil ->
          nil

        str ->
          case Integer.parse(str) do
            {n, ""} when n >= 0 -> n
            _ -> :invalid
          end
      end

    if cursor == :invalid do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        400,
        Jason.encode!(%{
          "error" => "InvalidRequest",
          "message" => "Error: Params must have a valid cursor"
        })
      )
      |> Plug.Conn.halt()
    else
      WebSockAdapter.upgrade(conn, AeroxWeb.Sockets.Firehose, %{cursor: cursor}, timeout: 60_000)
    end
  end
end
