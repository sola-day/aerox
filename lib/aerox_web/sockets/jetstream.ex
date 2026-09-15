defmodule AeroxWeb.Sockets.Jetstream do
  @moduledoc """
  Jetstream subscribers (upstream `internal/subscribe/handler.go`): the legacy
  v1 `/subscribe` and the v2 `network.bsky.jetstream.subscribeEvents`, one
  process per connection.

  The connection reads the log from its cursor a block (or 1024 rows) at a
  time, filters, encodes and pushes; at the tip it waits for the writer's
  notification. v1 subscribers may replace their filter with an
  `options_update` message (and, with `requireHello`, nothing is sent until
  the first); v2 is server-push only and a client data frame closes it. A
  subscriber far behind the tip (100,000 events) and advancing slower than 5
  events/s for a minute is dropped with `ConsumerTooSlow`.
  """
  @behaviour WebSock
  require Logger
  alias Aerox.Jetstream.{Config, Filter, Tail, Wire, Writer}

  @ping_ms 30_000

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(Aerox.PubSub, Writer.topic())
    Process.send_after(self(), :ping, @ping_ms)

    state =
      Map.merge(opts, %{
        waiting: false,
        streak: nil,
        hello?: not Map.get(opts, :require_hello, false)
      })

    if state.hello?, do: send(self(), :pump)

    case opts do
      %{v2: true, info: info} when is_binary(info) ->
        {:push, frame(state, Wire.v2_info("OutdatedCursor", info)), state}

      _ ->
        {:ok, state}
    end
  end

  @impl true
  def handle_in({text, [opcode: :text]}, %{v2: false} = state) do
    with {:ok, %{"type" => "options_update", "payload" => payload}} <- Jason.decode(text),
         {:ok, filter} <- Filter.v1_update(payload) do
      unless state.hello?, do: send(self(), :pump)
      {:ok, %{state | filter: filter, hello?: true}}
    else
      {:ok, %{"type" => other}} ->
        Logger.debug("jetstream: unknown subscriber message type #{inspect(other)}")
        {:ok, state}

      {:error, message} when is_binary(message) ->
        {:stop, :normal, {1008, String.slice(message, 0, 120)}, state}

      _ ->
        {:stop, :normal, {1007, "bad SubscriberSourcedMessage envelope"}, state}
    end
  end

  def handle_in(_frame, %{v2: true} = state), do: {:stop, :normal, 1008, state}
  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info(:pump, %{hello?: false} = state), do: {:ok, state}

  def handle_info(:pump, state) do
    case Tail.read_from(state.cursor, Config.read_batch()) do
      {:ok, [], next} when next == state.cursor ->
        {:ok, %{state | waiting: true}}

      {:ok, rows, next} ->
        frames =
          rows
          |> Enum.filter(&Filter.wants?(state.filter, &1))
          |> Enum.flat_map(&encode(state, &1))

        state = %{state | cursor: next, waiting: false}
        send(self(), :pump)

        case slow?(state) do
          {true, lag} ->
            error =
              Wire.v2_error(
                "ConsumerTooSlow",
                "reading below the floor rate #{lag} events behind the tip; reconnect with cursor=#{next}"
              )

            final = if state.v2, do: [frame(state, error)], else: []
            {:stop, :normal, 1008, frames ++ final, state}

          {false, streak} ->
            {:push, frames, %{state | streak: streak}}
        end

      {:error, reason} ->
        Logger.warning("jetstream: subscriber read failed: #{inspect(reason)}")

        final =
          if state.v2,
            do: [frame(state, Wire.v2_error("InternalError", "stream read failed; reconnect"))],
            else: []

        {:stop, :normal, 1011, final, state}
    end
  end

  def handle_info({:jetstream_appended, _seq}, %{waiting: true} = state) do
    send(self(), :pump)
    {:ok, %{state | waiting: false}}
  end

  def handle_info({:jetstream_appended, _}, state), do: {:ok, state}

  def handle_info(:ping, state) do
    Process.send_after(self(), :ping, @ping_ms)
    {:push, {:ping, ""}, state}
  end

  def handle_info(_, state), do: {:ok, state}

  @impl true
  def terminate(_, _), do: :ok

  # ---------------------------------------------------------------- frames

  defp encode(state, row) do
    result = if state.v2, do: Wire.v2(row), else: Wire.v1(row)

    case result do
      {:ok, body} ->
        cond do
          state.filter.max_bytes > 0 and byte_size(body) > state.filter.max_bytes -> []
          true -> [frame(state, body)]
        end

      :skip ->
        []

      {:error, reason} ->
        Logger.debug("jetstream: encode failed seq=#{row.seq}: #{inspect(reason)}")
        []
    end
  end

  defp frame(%{compress: true, v2: v2}, body),
    do: {:binary, Wire.compress(if(v2, do: :v2, else: :v1), body)}

  defp frame(_, body), do: {:text, body}

  # upstream slowDetector: far behind the tip and slower than the floor rate
  # for a whole window
  defp slow?(state) do
    tip = Writer.next_seq()
    lag = max(tip - state.cursor, 0)
    now = System.monotonic_time(:millisecond)

    cond do
      lag <= Config.slow_lag_threshold() ->
        {false, nil}

      state.streak == nil ->
        {false, {now, state.cursor}}

      true ->
        {start, pos} = state.streak
        elapsed = (now - start) / 1000

        cond do
          elapsed < Config.slow_window_ms() / 1000 -> {false, state.streak}
          (state.cursor - pos) / elapsed >= Config.slow_min_rate() -> {false, {now, state.cursor}}
          true -> {true, lag}
        end
    end
  end
end
