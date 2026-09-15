defmodule Aerox.Jetstream.Ingest do
  @moduledoc """
  Jetstream's relay consumer (upstream's live firehose consumer): one
  `subscribeRepos` connection to the Relay, resumed from the persisted relay
  cursor, each event turned into rows (`Aerox.Jetstream.Convert`) and appended
  with the cursor that produced them — or, while the bootstrap backfill runs,
  captured for the merge (`Aerox.Jetstream.Bootstrap`). A `#sync` queues a
  resync of its repo. Reconnects with capped exponential back-off; a peer
  silent for 75 s is presumed gone.
  """
  use GenServer
  require Logger
  alias Aerox.ATProto.Frame
  alias Aerox.Jetstream.{Bootstrap, Config, Convert, Resyncer, Store, Writer}

  @ping_every 30_000
  @dead_after 75_000
  @persist_every 5_000
  @max_backoff_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs `fun` inside the consumer, between events (the bootstrap's cut-over)."
  def exclusive(fun), do: GenServer.call(__MODULE__, {:exclusive, fun}, :infinity)

  @doc """
  Handles one relay event with `seq` (also what tests call directly). In the
  steady state rows are appended; during bootstrap they are captured.
  """
  def handle_event(type, body, seq, phase \\ Store.phase()) do
    {rows, drops} = Convert.rows(type, body)

    for {reason, detail} <- drops,
        do: Logger.debug("jetstream: dropped #{reason} #{inspect(detail)}")

    cond do
      rows == [] ->
        :noop

      phase == "steady_state" ->
        {:ok, _} = Writer.append(rows, cursor: seq)
        if type == "#sync", do: Resyncer.request(body["did"], body["rev"])
        :ok

      true ->
        :ok = Bootstrap.capture(rows, seq)
        :ok
    end
  end

  # ------------------------------------------------------------- server

  @impl true
  def init(_) do
    send(self(), :connect)
    :timer.send_interval(@ping_every, :ping)
    :timer.send_interval(@persist_every, :persist)
    cursor = Store.get("relay_cursor")

    {:ok,
     %{
       conn: nil,
       ws: nil,
       ref: nil,
       status: nil,
       backoff: 0,
       cursor: cursor,
       persisted: cursor,
       phase: Store.phase(),
       last_rx: now()
     }}
  end

  @impl true
  def handle_call({:exclusive, fun}, _from, state) do
    result = fun.()
    {:reply, result, %{state | phase: Store.phase()}}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state.cursor) do
      {:ok, conn, ref} ->
        {:noreply, %{state | conn: conn, ref: ref, ws: nil}}

      {:error, reason} ->
        Logger.warning("jetstream: relay dial failed reason=#{inspect(reason)}")
        {:noreply, retry(state)}
    end
  end

  def handle_info(:persist, state) do
    if state.cursor != state.persisted and state.cursor != nil do
      Store.put("relay_cursor", state.cursor)
      {:noreply, %{state | persisted: state.cursor}}
    else
      {:noreply, state}
    end
  end

  def handle_info(:ping, %{ws: ws, conn: conn} = state) when ws != nil and conn != nil do
    if now() - state.last_rx > @dead_after do
      Logger.warning("jetstream: relay silent for #{@dead_after}ms, reconnecting")
      {:noreply, retry(close(state))}
    else
      with {:ok, ws, bytes} <- Mint.WebSocket.encode(ws, {:ping, ""}),
           {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, state.ref, bytes) do
        {:noreply, %{state | ws: ws, conn: conn}}
      else
        _ -> {:noreply, retry(close(state))}
      end
    end
  end

  def handle_info(:ping, state), do: {:noreply, state}

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn, last_rx: now()}

        case Enum.reduce_while(responses, {:ok, state}, &response/2) do
          {:ok, state} -> {:noreply, state}
          {:reconnect, state} -> {:noreply, retry(close(state))}
        end

      {:error, conn, reason, _} ->
        Logger.warning("jetstream: relay connection error reason=#{inspect(reason)}")
        {:noreply, retry(close(%{state | conn: conn}))}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp response({:status, ref, status}, {:ok, %{ref: ref} = state}) do
    if status == 101,
      do: {:cont, {:ok, %{state | status: status}}},
      else: {:halt, {:reconnect, state}}
  end

  defp response({:headers, ref, headers}, {:ok, %{ref: ref} = state}) do
    case Mint.WebSocket.new(state.conn, ref, state.status, headers) do
      {:ok, conn, ws} ->
        Logger.info("jetstream: relay connected cursor=#{inspect(state.cursor)}")
        {:cont, {:ok, %{state | conn: conn, ws: ws, backoff: 0}}}

      {:error, conn, _reason} ->
        {:halt, {:reconnect, %{state | conn: conn}}}
    end
  end

  defp response({:data, ref, data}, {:ok, %{ref: ref, ws: ws} = state}) when ws != nil do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} ->
        case Enum.reduce_while(frames, {:ok, %{state | ws: ws}}, &frame/2) do
          {:ok, state} -> {:cont, {:ok, state}}
          other -> {:halt, other}
        end

      {:error, ws, _} ->
        {:halt, {:reconnect, %{state | ws: ws}}}
    end
  end

  defp response(_, acc), do: {:cont, acc}

  defp frame({:binary, bytes}, {:ok, state}) do
    case Frame.decode(bytes) do
      {:ok, {:message, type, %{"seq" => seq} = body}} when is_integer(seq) ->
        _ = handle_event(type, body, seq, state.phase)

        {:cont,
         {:ok,
          %{
            state
            | cursor: seq,
              persisted: if(state.phase == "steady_state", do: seq, else: state.persisted)
          }}}

      {:ok, {:message, _type, _body}} ->
        {:cont, {:ok, state}}

      {:ok, {:error, "FutureCursor", _}} ->
        Logger.warning("jetstream: relay says our cursor is in the future; resuming from its tip")
        Store.put("relay_cursor", nil)
        {:halt, {:reconnect, %{state | cursor: nil, persisted: nil}}}

      {:ok, {:error, name, msg}} ->
        Logger.warning("jetstream: relay error frame #{name}: #{inspect(msg)}")
        {:cont, {:ok, state}}

      {:error, reason} ->
        Logger.warning("jetstream: undecodable relay frame #{inspect(reason)}")
        {:cont, {:ok, state}}
    end
  end

  defp frame({:ping, data}, {:ok, state}) do
    {:ok, ws, bytes} = Mint.WebSocket.encode(state.ws, {:pong, data})
    {:ok, conn} = Mint.WebSocket.stream_request_body(state.conn, state.ref, bytes)
    {:cont, {:ok, %{state | ws: ws, conn: conn}}}
  end

  defp frame({:close, _, _}, {:ok, state}), do: {:halt, {:reconnect, state}}
  defp frame(_, acc), do: {:cont, acc}

  defp connect(cursor) do
    uri = URI.parse(Config.relay_url())
    {http, ws} = if uri.scheme in ["wss", "https"], do: {:https, :wss}, else: {:http, :ws}
    query = if cursor, do: "?cursor=#{cursor}", else: ""

    with {:ok, conn} <- Mint.HTTP.connect(http, uri.host, uri.port, protocols: [:http1]),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(ws, conn, "/xrpc/com.atproto.sync.subscribeRepos" <> query, [
             {"user-agent", "aerox-jetstream"}
           ]) do
      {:ok, conn, ref}
    else
      {:error, reason} -> {:error, reason}
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  defp retry(state) do
    backoff = state.backoff + 1

    Process.send_after(
      self(),
      :connect,
      min(@max_backoff_ms, trunc(:math.pow(2, min(backoff, 16)) * 250))
    )

    %{state | backoff: backoff}
  end

  defp close(%{conn: nil} = state), do: state

  defp close(state) do
    _ = Mint.HTTP.close(state.conn)
    %{state | conn: nil, ws: nil, ref: nil}
  end

  defp now, do: System.monotonic_time(:millisecond)
end
