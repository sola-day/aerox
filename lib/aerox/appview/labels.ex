defmodule Aerox.AppView.Labels do
  @moduledoc """
  Label consumption (DESIGN §15.6): one `Aerox.AppView.Labels.Consumer` per
  configured labeler (`config :aerox, Aerox.AppView, labelers: [%{did:,
  url:}]`) subscribes to its `com.atproto.label.subscribeLabels` and
  upserts `appview.label`; the cursor is persisted per labeler in
  `appview.label_subscription`. `apply/1` is the write path the consumers
  (and tests) use: a label replaces the row for its `(src, uri, cid, val)`,
  so a `neg: true` label negates the earlier one — hydration reads only
  `neg == false` rows, as upstream's does.
  """
  use Supervisor
  import Ecto.Query
  require Logger
  alias Aerox.ATProto.{Bytes, Syntax}
  alias Aerox.AppView.{Config, Repo}
  alias Aerox.AppView.Schema, as: S

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    labelers = Keyword.get(opts, :labelers, Config.labelers())

    children =
      for %{did: did, url: url} <- labelers do
        Supervisor.child_spec({Aerox.AppView.Labels.Consumer, did: did, url: url},
          id: {:labeler, did}
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  # ------------------------------------------------------------- writes

  @doc "Upserts wire-form labels (string keys; `sig` as `Bytes` or `$bytes`); returns the number applied."
  @spec apply([map] | map) :: non_neg_integer
  def apply(%{} = label), do: __MODULE__.apply([label])

  def apply(labels) when is_list(labels) do
    rows =
      labels
      |> Enum.map(&to_row/1)
      |> Enum.reject(&is_nil/1)
      # one row per key within a batch, last write wins
      |> Enum.reverse()
      |> Enum.uniq_by(&{&1.src, &1.uri, &1.cid, &1.val})
      |> Enum.reverse()

    if rows == [] do
      0
    else
      {n, _} =
        Repo.insert_all(S.Label, rows,
          on_conflict: {:replace, [:neg, :cts, :exp, :sig]},
          conflict_target: [:src, :uri, :cid, :val]
        )

      n
    end
  end

  defp to_row(%{"src" => src, "uri" => uri, "val" => val, "cts" => cts} = l)
       when is_binary(src) and is_binary(uri) and is_binary(val) do
    with {:ok, cts} <- Syntax.parse_datetime(cts),
         {:ok, exp} <- optional_datetime(l["exp"]) do
      %{
        src: src,
        uri: uri,
        cid: l["cid"] || "",
        val: val,
        neg: l["neg"] == true,
        cts: usec(cts),
        exp: exp && usec(exp),
        sig: sig_bytes(l["sig"])
      }
    else
      _ ->
        Logger.warning("appview: label with invalid timestamps dropped: #{inspect(l)}")
        nil
    end
  end

  defp to_row(l) do
    Logger.warning("appview: malformed label dropped: #{inspect(l)}")
    nil
  end

  # the column type wants microsecond precision whatever the string carried
  defp usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

  defp optional_datetime(nil), do: {:ok, nil}
  defp optional_datetime(str), do: Syntax.parse_datetime(str)

  defp sig_bytes(%Bytes{data: data}), do: data
  defp sig_bytes(%{"$bytes" => b64}), do: Base.decode64!(b64, padding: false)
  defp sig_bytes(bin) when is_binary(bin), do: bin
  defp sig_bytes(_), do: nil

  # ------------------------------------------------------------- cursors

  @doc "The persisted cursor for a labeler (0 when none)."
  def cursor(src) do
    Repo.one(from(s in S.LabelSubscription, where: s.src == ^src, select: s.cursor)) || 0
  end

  def put_cursor(src, cursor) do
    Repo.insert_all(
      S.LabelSubscription,
      [%{src: src, cursor: cursor, updated_at: DateTime.utc_now()}],
      on_conflict: {:replace, [:cursor, :updated_at]},
      conflict_target: [:src]
    )

    :ok
  end
end

defmodule Aerox.AppView.Labels.Consumer do
  @moduledoc """
  A `subscribeLabels` client for one labeler over Mint.WebSocket (the same
  shape as `Aerox.AppView.Ingest.Producer`): connects with the persisted
  cursor, applies each `#labels` frame as it arrives, persists the cursor
  every few seconds and on exit, reconnects with backoff, and resets the
  cursor on `FutureCursor`. Labels whose `src` is not the subscribed
  labeler are ignored.
  """
  use GenServer
  require Logger
  alias Aerox.ATProto.Frame
  alias Aerox.AppView.Labels

  @persist_every 3_000
  @ping_every 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    did = Keyword.fetch!(opts, :did)
    url = Keyword.fetch!(opts, :url)
    cursor = Labels.cursor(did)
    if Keyword.get(opts, :connect, true), do: send(self(), :connect)
    :timer.send_interval(Keyword.get(opts, :persist_every, @persist_every), :persist)
    :timer.send_interval(@ping_every, :ping)

    {:ok,
     %{
       did: did,
       url: url,
       conn: nil,
       ws: nil,
       ref: nil,
       status: nil,
       backoff: 0,
       cursor: cursor,
       persisted: cursor
     }}
  end

  @doc "Handles one decoded frame; exposed so tests can drive the consumer without a socket."
  def handle_frame({:message, "#labels", %{"seq" => seq, "labels" => labels}}, state)
      when is_integer(seq) and is_list(labels) do
    mine = Enum.filter(labels, &(&1["src"] == state.did))
    if mine != [], do: Labels.apply(mine)
    %{state | cursor: max(state.cursor, seq)}
  end

  def handle_frame({:message, "#info", body}, state) do
    Logger.info("appview: labels #{state.did} info #{inspect(body)}")
    state
  end

  def handle_frame({:error, name, msg}, state) do
    Logger.warning("appview: labels #{state.did} error frame #{name}: #{inspect(msg)}")

    state =
      if name == "FutureCursor" do
        Labels.put_cursor(state.did, 0)
        %{state | cursor: 0, persisted: 0}
      else
        state
      end

    mark_reconnect(state)
  end

  def handle_frame(_, state), do: state

  # ---------------------------------------------------------- connection

  @impl true
  def handle_info(:connect, state) do
    case connect(state.url, state.cursor) do
      {:ok, conn, ref} ->
        {:noreply, %{state | conn: conn, ref: ref, ws: nil}}

      {:error, reason} ->
        Logger.warning("appview: labels dial failed url=#{state.url} reason=#{inspect(reason)}")
        {:noreply, retry(state)}
    end
  end

  def handle_info(:persist, state), do: {:noreply, persist(state)}

  def handle_info(:ping, %{ws: ws, conn: conn} = state) when ws != nil and conn != nil do
    with {:ok, ws, bytes} <- Mint.WebSocket.encode(ws, {:ping, ""}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(conn, state.ref, bytes) do
      {:noreply, %{state | ws: ws, conn: conn}}
    else
      _ -> {:noreply, retry(close(state))}
    end
  end

  def handle_info(:ping, state), do: {:noreply, state}

  def handle_info(message, %{conn: conn} = state) when conn != nil and conn != :reconnect do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = Enum.reduce(responses, %{state | conn: conn}, &handle_response/2)

        if state.conn == :reconnect,
          do: {:noreply, retry(close(%{state | conn: conn}))},
          else: {:noreply, state}

      {:error, conn, reason, _} ->
        Logger.warning("appview: labels #{state.did} socket error #{inspect(reason)}")
        {:noreply, retry(close(%{state | conn: conn}))}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp handle_response({:status, ref, status}, %{ref: ref} = state), do: %{state | status: status}

  defp handle_response({:headers, ref, headers}, %{ref: ref} = state) do
    case Mint.WebSocket.new(state.conn, ref, state.status, headers) do
      {:ok, conn, ws} ->
        Logger.info("appview: labels connected did=#{state.did} cursor=#{state.cursor}")
        %{state | conn: conn, ws: ws, backoff: 0}

      {:error, conn, reason} ->
        Logger.warning("appview: labels handshake failed reason=#{inspect(reason)}")
        mark_reconnect(%{state | conn: conn})
    end
  end

  defp handle_response({:data, ref, data}, %{ref: ref, ws: ws} = state) when ws != nil do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} -> Enum.reduce(frames, %{state | ws: ws}, &handle_ws_frame/2)
      {:error, ws, _} -> mark_reconnect(%{state | ws: ws})
    end
  end

  defp handle_response(_, state), do: state

  defp handle_ws_frame({:binary, bytes}, state) do
    case Frame.decode(bytes) do
      {:ok, frame} -> handle_frame(frame, state)
      _ -> state
    end
  end

  defp handle_ws_frame({:close, _, _}, state), do: mark_reconnect(state)

  defp handle_ws_frame({:ping, data}, state) do
    with {:ok, ws, bytes} <- Mint.WebSocket.encode(state.ws, {:pong, data}),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, bytes) do
      %{state | ws: ws, conn: conn}
    else
      _ -> state
    end
  end

  defp handle_ws_frame(_, state), do: state

  defp mark_reconnect(state), do: %{state | conn: :reconnect}

  defp connect(url, cursor) do
    uri = URI.parse(url)

    {http_scheme, ws_scheme} =
      if uri.scheme in ["wss", "https"], do: {:https, :wss}, else: {:http, :ws}

    path = "/xrpc/com.atproto.label.subscribeLabels?cursor=#{cursor}"

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

  defp close(%{conn: conn} = state) when conn not in [nil, :reconnect] do
    _ = Mint.HTTP.close(conn)
    %{state | conn: nil, ws: nil, ref: nil}
  end

  defp close(state), do: %{state | conn: nil, ws: nil, ref: nil}

  defp persist(%{cursor: c, persisted: p} = state) when c > p do
    Labels.put_cursor(state.did, c)
    %{state | persisted: c}
  end

  defp persist(state), do: state

  @impl true
  def terminate(_reason, state) do
    _ = persist(state)
    _ = close(state)
    :ok
  end
end
