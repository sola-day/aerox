defmodule Aerox.AppView.Ingest.Producer do
  @moduledoc """
  Broadway producer over the Relay's `subscribeRepos` (DESIGN §15.1, §21.5).
  Frames are decoded and queued; demand drains the queue. The cursor is the
  last seq acked by the pipeline: `ack/3` records completed seqs, and the
  persisted cursor is the highest seq below which nothing is still in
  flight — so a restart resumes with no gap and no duplicate.

  Back-pressure reaches the socket by disconnecting when the queue exceeds
  `@high_water` (BEAM mailboxes are unbounded; the frames must not pile up)
  and reconnecting from the persisted cursor once it drains.
  """
  use GenStage
  require Logger
  alias Aerox.ATProto.Frame
  alias Aerox.AppView.Ingest.Cursor

  @behaviour Broadway.Producer

  @high_water 5_000
  @low_water 500
  @persist_every 3_000
  @ping_every 30_000
  # VERIFICATION §10.3 "half-open connections": a peer that stopped answering
  # (no data, no pong) for this long is dead; reconnect from the cursor.
  @dead_after 75_000

  def start_link(opts), do: GenStage.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    service = Keyword.get(opts, :service, url)
    connect? = Keyword.get(opts, :connect, true)
    cursor = Cursor.get(service)
    if connect?, do: send(self(), :connect)
    :timer.send_interval(@persist_every, :persist)
    :timer.send_interval(@ping_every, :ping)

    {:producer,
     %{
       url: url,
       service: service,
       conn: nil,
       ws: nil,
       ref: nil,
       status: nil,
       queue: :queue.new(),
       queued: 0,
       demand: 0,
       backoff: 0,
       last_rx: System.monotonic_time(:millisecond),
       paused: false,
       cursor: cursor,
       persisted: cursor,
       in_flight: MapSet.new(),
       highest_seen: cursor
     }}
  end

  @impl true
  def handle_demand(demand, state), do: dispatch(%{state | demand: state.demand + demand})

  # Broadway calls this on the producer process for each batch outcome.
  @impl Broadway.Producer
  def prepare_for_start(_module, broadway_opts), do: {[], broadway_opts}

  def ack(producer, successful, failed) do
    seqs = for %Broadway.Message{data: %{seq: seq}} <- successful ++ failed, do: seq
    send(producer, {:acked, seqs})
    :ok
  end

  # ------------------------------------------------------------- dispatch

  defp dispatch(%{demand: demand, queued: queued} = state) when demand > 0 and queued > 0 do
    {events, state} = take(state, min(demand, queued), [])
    state = maybe_resume(state)
    {:noreply, events, state}
  end

  defp dispatch(state), do: {:noreply, [], state}

  defp take(state, 0, acc), do: {Enum.reverse(acc), state}

  defp take(state, n, acc) do
    {{:value, event}, queue} = :queue.out(state.queue)

    msg = %Broadway.Message{
      data: event,
      acknowledger: {__MODULE__, self(), nil}
    }

    state = %{
      state
      | queue: queue,
        queued: state.queued - 1,
        demand: state.demand - 1,
        in_flight: MapSet.put(state.in_flight, event.seq)
    }

    take(state, n - 1, [msg | acc])
  end

  # ---------------------------------------------------------- connection

  @impl true
  def handle_info(:connect, %{paused: true} = state), do: {:noreply, [], state}

  def handle_info(:connect, state) do
    case connect(state.url, state.cursor) do
      {:ok, conn, ref} ->
        {:noreply, [], %{state | conn: conn, ref: ref, ws: nil}}

      {:error, reason} ->
        Logger.warning("appview: firehose dial failed url=#{state.url} reason=#{inspect(reason)}")
        {:noreply, [], retry(state)}
    end
  end

  def handle_info({:acked, seqs}, state) do
    in_flight = Enum.reduce(seqs, state.in_flight, &MapSet.delete(&2, &1))
    {:noreply, [], %{state | in_flight: in_flight}}
  end

  def handle_info(:persist, state), do: {:noreply, [], persist(state)}

  def handle_info(:ping, %{ws: ws, conn: conn} = state) when ws != nil and conn != nil do
    if System.monotonic_time(:millisecond) - state.last_rx > @dead_after do
      Logger.warning("appview: firehose peer silent for #{@dead_after}ms, reconnecting")
      {:noreply, [], retry(close(state))}
    else
      with {:ok, ws, bytes} <- Mint.WebSocket.encode(ws, {:ping, ""}),
           {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, state.ref, bytes) do
        {:noreply, [], %{state | ws: ws, conn: conn}}
      else
        _ -> {:noreply, [], retry(close(state))}
      end
    end
  end

  def handle_info(:ping, state), do: {:noreply, [], state}

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn, last_rx: System.monotonic_time(:millisecond)}
        state = Enum.reduce(responses, state, &handle_response/2)

        if state.conn == :reconnect,
          do: {:noreply, [], retry(close(%{state | conn: conn}))},
          else: dispatch(state)

      {:error, conn, reason, _} ->
        Logger.warning("appview: firehose error reason=#{inspect(reason)}")
        {:noreply, [], retry(close(%{state | conn: conn}))}

      :unknown ->
        {:noreply, [], state}
    end
  end

  def handle_info(_, state), do: {:noreply, [], state}

  defp handle_response({:status, ref, status}, %{ref: ref} = state), do: %{state | status: status}

  defp handle_response({:headers, ref, headers}, %{ref: ref} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.status, headers) do
      {:ok, conn, ws} ->
        Logger.info("appview: firehose connected url=#{state.url} cursor=#{state.cursor}")
        %{state | conn: conn, ws: ws, backoff: 0, last_rx: System.monotonic_time(:millisecond)}

      {:error, conn, reason} ->
        Logger.warning("appview: firehose handshake failed reason=#{inspect(reason)}")
        %{state | conn: conn} |> mark_reconnect()
    end
  end

  defp handle_response({:data, ref, data}, %{ref: ref, ws: ws} = state) when ws != nil do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} -> Enum.reduce(frames, %{state | ws: ws}, &handle_frame/2)
      {:error, ws, _} -> mark_reconnect(%{state | ws: ws})
    end
  end

  defp handle_response(_, state), do: state

  defp handle_frame({:binary, bytes}, state) do
    case Frame.decode(bytes) do
      {:ok, {:message, type, %{"seq" => seq} = body}} when is_integer(seq) ->
        state =
          enqueue(state, %{seq: seq, type: type, body: body, did: body["did"] || body["repo"]})

        %{state | highest_seen: max(state.highest_seen, seq)}

      {:ok, {:message, "#info", body}} ->
        Logger.info("appview: firehose info #{inspect(body)}")
        state

      {:ok, {:error, name, msg}} ->
        Logger.warning("appview: firehose error frame #{name}: #{inspect(msg)}")
        if name == "FutureCursor", do: Cursor.reset(state.service)
        mark_reconnect(state)

      _ ->
        state
    end
  end

  defp handle_frame({:close, _, _}, state), do: mark_reconnect(state)

  defp handle_frame({:ping, data}, state) do
    with {:ok, ws, bytes} <- Mint.WebSocket.encode(state.ws, {:pong, data}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, bytes) do
      %{state | ws: ws, conn: conn}
    else
      _ -> state
    end
  end

  defp handle_frame(_, state), do: state

  defp enqueue(state, event) do
    state = %{state | queue: :queue.in(event, state.queue), queued: state.queued + 1}

    if state.queued >= @high_water and not state.paused do
      Logger.warning("appview: firehose queue full (#{state.queued}); pausing until drained")
      %{close(state) | paused: true}
    else
      state
    end
  end

  defp maybe_resume(%{paused: true, queued: q} = state) when q <= @low_water do
    send(self(), :connect)
    %{state | paused: false}
  end

  defp maybe_resume(state), do: state

  defp mark_reconnect(state), do: %{state | conn: :reconnect}

  defp connect(url, cursor) do
    uri = URI.parse(url)

    {http_scheme, ws_scheme} =
      if uri.scheme in ["wss", "https"], do: {:https, :wss}, else: {:http, :ws}

    # always with a cursor: a fresh AppView asks for everything the Relay
    # retains (cursor=0 → OutdatedCursor + replay from the window start),
    # never a live-only tail that would miss the existing repos
    path = "/xrpc/com.atproto.sync.subscribeRepos?cursor=#{cursor}"

    with {:ok, conn} <- Mint.HTTP.connect(http_scheme, uri.host, uri.port, protocols: [:http1]),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(ws_scheme, conn, path, [{"user-agent", "aerox-appview"}]) do
      {:ok, conn, ref}
    else
      {:error, reason} -> {:error, reason}
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  defp retry(state) do
    backoff = state.backoff + 1
    Process.send_after(self(), :connect, min(60_000, trunc(:math.pow(2, min(backoff, 16)) * 250)))
    %{state | backoff: backoff}
  end

  defp close(%{conn: conn} = state) when conn not in [nil, :reconnect],
    do:
      (
        _ = Mint.HTTP.close(conn)
        %{state | conn: nil, ws: nil, ref: nil}
      )

  defp close(state), do: %{state | conn: nil, ws: nil, ref: nil}

  # The durable cursor: everything up to it is acked; nothing below it is in flight or queued.
  defp persist(state) do
    floor =
      case {Enum.min(state.in_flight, fn -> nil end), :queue.peek(state.queue)} do
        {nil, :empty} -> state.highest_seen
        {nil, {:value, %{seq: s}}} -> s - 1
        {min_in_flight, :empty} -> min_in_flight - 1
        {min_in_flight, {:value, %{seq: s}}} -> min(min_in_flight, s) - 1
      end

    cursor = max(state.cursor, floor)

    if cursor > state.persisted do
      Cursor.put(state.service, cursor)
      %{state | cursor: cursor, persisted: cursor}
    else
      %{state | cursor: cursor}
    end
  end

  @impl true
  def terminate(_reason, state) do
    _ = persist(state)
    _ = close(state)
    :ok
  end
end
