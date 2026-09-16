defmodule Aerox.Relay.Consumer do
  @moduledoc """
  One GenServer per upstream host (DESIGN §21.4, indigo `slurper.go`): opens
  `subscribeRepos?cursor=<host.last_seq>` over Mint.WebSocket, decodes each
  frame, hands it to `Aerox.Relay.Ingest`, tracks the upstream seq and
  persists it every few seconds and on exit. Connection failures reconnect
  with exponential back-off (capped); after many consecutive failures the
  host is marked `offline`. A `FutureCursor` error frame from the host marks
  it `idle` and stops (the operator resets the cursor). Verification
  failures count against the host; past `max_host_errors` the host is
  `throttled` and the consumer stops — a persistent offender is paused, not
  restarted every second.
  """
  use GenServer, restart: :transient
  require Logger
  alias Aerox.ATProto.Frame
  alias Aerox.Relay.{Hosts, Ingest}
  alias Aerox.Relay.Schema.Host

  @persist_every 4_000
  @ping_every 30_000
  @max_backoff_ms 60_000
  # VERIFICATION §10.3 "half-open connections": no data and no pong for this
  # long means the peer is gone; reconnect from the cursor.
  @dead_after 75_000
  @offline_after 16

  def start_link(%Host{} = host) do
    GenServer.start_link(__MODULE__, host, name: via(host.hostname))
  end

  def via(hostname), do: {:via, Registry, {Aerox.Relay.ConsumerRegistry, hostname}}

  @doc "The consumer's live view: cursor, connection state, error count."
  def status(hostname), do: GenServer.call(via(hostname), :status)

  @impl true
  def init(%Host{} = host) do
    Process.flag(:trap_exit, true)
    send(self(), :connect)
    persist_every = Application.get_env(:aerox, __MODULE__, [])[:persist_every] || @persist_every
    :timer.send_interval(persist_every, :persist)
    :timer.send_interval(@ping_every, :ping)

    {:ok,
     %{
       host: host,
       cursor: max(host.last_seq, 0),
       persisted: max(host.last_seq, 0),
       conn: nil,
       ws: nil,
       ref: nil,
       backoff: 0,
       last_rx: System.monotonic_time(:millisecond),
       connected?: false,
       buffer: <<>>
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, Map.take(state, [:cursor, :persisted, :connected?, :backoff]), state}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state.host, state.cursor) do
      {:ok, conn, ref} ->
        {:noreply, %{state | conn: conn, ref: ref, ws: nil, connected?: false}}

      {:error, reason} ->
        Logger.warning(
          "relay: dial failed host=#{state.host.hostname} backoff=#{state.backoff} reason=#{inspect(reason)}"
        )

        retry(%{state | conn: nil, ws: nil, connected?: false})
    end
  end

  def handle_info(:persist, state), do: {:noreply, persist(state)}

  # keepalive: a ping every 30 s so idle-timeout proxies and servers keep the socket
  def handle_info(:ping, %{ws: ws, conn: conn} = state) when ws != nil and conn != nil do
    if System.monotonic_time(:millisecond) - state.last_rx > @dead_after do
      Logger.warning(
        "relay: host silent for #{@dead_after}ms host=#{state.host.hostname}, reconnecting"
      )

      retry(close(state))
    else
      with {:ok, ws, bytes} <- Mint.WebSocket.encode(ws, {:ping, ""}),
           {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, state.ref, bytes) do
        {:noreply, %{state | ws: ws, conn: conn}}
      else
        _ -> retry(close(state))
      end
    end
  end

  def handle_info(:ping, state), do: {:noreply, state}

  def handle_info({:stop_host, status}, state), do: stop_host(status, state)

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn, last_rx: System.monotonic_time(:millisecond)}

        case Enum.reduce_while(responses, {:ok, state}, &handle_response/2) do
          {:ok, state} -> {:noreply, state}
          {:stop, reason, state} -> stop_host(reason, state)
          {:reconnect, state} -> retry(close(state))
        end

      {:error, conn, reason, _responses} ->
        Logger.warning(
          "relay: connection error host=#{state.host.hostname} reason=#{inspect(reason)}"
        )

        retry(close(%{state | conn: conn}))

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ------------------------------------------------------------ responses

  defp handle_response({:status, ref, status}, {:ok, %{ref: ref} = state}) do
    if status == 101 do
      {:cont, {:ok, Map.put(state, :upgrade_status, status)}}
    else
      Logger.warning("relay: upgrade refused host=#{state.host.hostname} status=#{status}")
      {:halt, {:reconnect, state}}
    end
  end

  defp handle_response({:headers, ref, headers}, {:ok, %{ref: ref} = state}) do
    case Mint.WebSocket.new(state.conn, ref, state.upgrade_status, headers) do
      {:ok, conn, ws} ->
        Logger.info("relay: connected host=#{state.host.hostname} cursor=#{state.cursor}")

        {:cont,
         {:ok,
          %{
            state
            | conn: conn,
              ws: ws,
              connected?: true,
              backoff: 0,
              last_rx: System.monotonic_time(:millisecond)
          }}}

      {:error, conn, reason} ->
        Logger.warning(
          "relay: websocket handshake failed host=#{state.host.hostname} reason=#{inspect(reason)}"
        )

        {:halt, {:reconnect, %{state | conn: conn}}}
    end
  end

  defp handle_response({:data, ref, data}, {:ok, %{ref: ref, ws: ws} = state}) when ws != nil do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} ->
        state = %{state | ws: ws}

        Enum.reduce_while(frames, {:ok, state}, &handle_frame/2)
        |> then(&{:cont, &1})
        |> unwrap_halt()

      {:error, ws, reason} ->
        Logger.warning(
          "relay: frame decode error host=#{state.host.hostname} reason=#{inspect(reason)}"
        )

        {:halt, {:reconnect, %{state | ws: ws}}}
    end
  end

  # `:done` here is the end of the 101 response itself, not of the stream;
  # a closed socket surfaces as a `:close` frame or a transport error.
  defp handle_response({:done, ref}, {:ok, %{ref: ref} = state}), do: {:cont, {:ok, state}}
  defp handle_response(_, acc), do: {:cont, acc}

  defp unwrap_halt({:cont, {:ok, state}}), do: {:cont, {:ok, state}}
  defp unwrap_halt({:cont, other}), do: {:halt, other}

  defp handle_frame({:binary, bytes}, {:ok, state}) do
    case Frame.decode(bytes) do
      {:ok, {:message, type, %{"seq" => seq} = body}} when is_integer(seq) ->
        state = process(state, type, body)
        {:cont, {:ok, %{state | cursor: max(state.cursor, seq)}}}

      {:ok, {:message, "#info", body}} ->
        Logger.info("relay: info from host=#{state.host.hostname} #{inspect(body)}")
        {:cont, {:ok, state}}

      {:ok, {:message, type, body}} ->
        {:cont, {:ok, process(state, type, body)}}

      {:ok, {:error, "FutureCursor", msg}} ->
        Logger.warning(
          "relay: host rejected cursor as future host=#{state.host.hostname} msg=#{inspect(msg)}"
        )

        {:halt, {:stop, :idle, state}}

      {:ok, {:error, name, msg}} ->
        Logger.warning("relay: error frame host=#{state.host.hostname} #{name}: #{inspect(msg)}")
        {:cont, {:ok, state}}

      {:error, reason} ->
        Logger.warning(
          "relay: undecodable frame host=#{state.host.hostname} reason=#{inspect(reason)}"
        )

        {:cont, {:ok, count_error(state)}}
    end
  end

  defp handle_frame({:ping, data}, {:ok, state}) do
    {:ok, ws, bytes} = Mint.WebSocket.encode(state.ws, {:pong, data})
    {:ok, conn} = Mint.WebSocket.stream_request_body(state.conn, state.ref, bytes)
    {:cont, {:ok, %{state | ws: ws, conn: conn}}}
  end

  defp handle_frame({:close, code, reason}, {:ok, state}) do
    Logger.info(
      "relay: host closed host=#{state.host.hostname} code=#{code} reason=#{inspect(reason)}"
    )

    {:halt, {:reconnect, state}}
  end

  defp handle_frame(_, acc), do: {:cont, acc}

  defp process(state, type, body) do
    case Ingest.process(state.host, type, body) do
      :ok ->
        state

      {:dropped, reason} ->
        Logger.debug(
          "relay: dropped event host=#{state.host.hostname} type=#{type} reason=#{inspect(reason)}"
        )

        state

      {:error, reason} ->
        Logger.warning(
          "relay: rejected event host=#{state.host.hostname} type=#{type} reason=#{inspect(reason)}"
        )

        count_error(state)
    end
  end

  defp count_error(state) do
    case Hosts.record_error(state.host.id) do
      :ok -> state
      :paused -> throw({:paused, state})
    end
  catch
    {:paused, state} ->
      Logger.error("relay: host paused after too many errors host=#{state.host.hostname}")
      send(self(), {:stop_host, :throttled})
      state
  end

  # -------------------------------------------------------------- connect

  defp connect(%Host{} = host, cursor) do
    url = URI.parse(Hosts.firehose_url(host, cursor))
    {http_scheme, ws_scheme} = if url.scheme == "wss", do: {:https, :wss}, else: {:http, :ws}
    path = url.path <> if(url.query, do: "?" <> url.query, else: "")

    with {:ok, conn} <-
           Mint.HTTP.connect(http_scheme, url.host, url.port,
             protocols: [:http1],
             transport_opts: transport_opts(host)
           ),
         {:ok, conn, ref} <-
           Mint.WebSocket.upgrade(ws_scheme, conn, path, [{"user-agent", "aerox-relay"}]) do
      {:ok, conn, ref}
    else
      {:error, reason} -> {:error, reason}
      {:error, _conn, reason} -> {:error, reason}
    end
  end

  defp transport_opts(%Host{no_ssl: true}), do: []

  defp transport_opts(_),
    do: Keyword.get(Application.get_env(:aerox, __MODULE__, []), :transport_opts, [])

  defp retry(state) do
    backoff = state.backoff + 1

    if backoff > @offline_after and state.persisted == state.cursor do
      Hosts.update_status(state.host.id, "offline")
    end

    delay = min(@max_backoff_ms, trunc(:math.pow(2, min(backoff, 16)) * 250))
    Process.send_after(self(), :connect, delay)
    {:noreply, %{state | backoff: backoff}}
  end

  defp close(%{conn: nil} = state), do: state

  defp close(state) do
    _ = Mint.HTTP.close(state.conn)
    %{state | conn: nil, ws: nil, ref: nil, connected?: false}
  end

  defp persist(%{cursor: c, persisted: p} = state) when c > p do
    Hosts.persist_cursor(state.host.id, c)
    %{state | persisted: c}
  end

  defp persist(state), do: state

  # the cursor first, then the status: persisting it can take an idle or
  # offline host back to active, which would undo the status set here
  defp stop_host(status, state) do
    state = persist(state)
    Hosts.update_status(state.host.id, to_string(status))
    {:stop, :normal, close(state)}
  end

  @impl true
  def handle_continue(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = persist(state)
    _ = close(state)
    :ok
  end
end
