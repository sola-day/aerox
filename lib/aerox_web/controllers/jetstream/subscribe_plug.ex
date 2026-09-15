defmodule AeroxWeb.Jetstream.SubscribePlug do
  @moduledoc """
  The pre-upgrade half of a Jetstream subscription (upstream `serve`): refuse
  before the bootstrap finishes, parse the filter and the compression opt-in,
  resolve the cursor, then hand the connection to `AeroxWeb.Sockets.Jetstream`.

  v1 errors are plain-text bodies, as upstream's `http.Error`; v2 errors are
  XRPC JSON (`InvalidRequest`, `CursorTooOld`, `UnknownZstdDictionary`,
  `ServiceUnavailable`).
  """
  @behaviour Plug
  import Plug.Conn
  alias Aerox.Jetstream.{Cursor, Filter, Store, Wire}

  @subprotocol "xrpc.v1.json"

  @impl true
  def init(version), do: version

  @impl true
  def call(conn, version) do
    v2? = version == :v2
    pairs = Filter.pairs(conn.query_string)

    with :ok <-
           if(Store.steady_state?(),
             do: :ok,
             else: {:error, 503, "ServiceUnavailable", "service not ready: bootstrap in progress"}
           ),
         {:ok, compress?} <- compression(conn, pairs, v2?),
         {:ok, filter} <- filter(pairs, v2?),
         {:ok, plan} <- cursor(pairs, v2?),
         :ok <- upgradable(conn) do
      state = %{
        v2: v2?,
        filter: filter,
        compress: compress?,
        cursor: plan.start,
        require_hello:
          not v2? and List.keyfind(pairs, "requireHello", 0) == {"requireHello", "true"},
        info:
          if(v2? and plan.clamped and plan.mode == :time,
            do: "requested timestamp cursor below retention floor; starting at seq #{plan.start}"
          )
      }

      conn =
        if v2? and wants_subprotocol?(conn),
          do: put_resp_header(conn, "sec-websocket-protocol", @subprotocol),
          else: conn

      conn
      |> WebSockAdapter.upgrade(AeroxWeb.Sockets.Jetstream, state,
        timeout: 120_000,
        compress: not v2? and not compress?
      )
      |> halt()
    else
      {:error, status, name, message} -> error(conn, v2?, status, name, message)
    end
  end

  defp compression(conn, pairs, false) do
    wants =
      List.keyfind(pairs, "compress", 0) == {"compress", "true"} or socket_encoding_zstd?(conn)

    {:ok, wants}
  end

  defp compression(conn, pairs, true) do
    cond do
      List.keyfind(pairs, "compress", 0) == {"compress", "true"} or socket_encoding_zstd?(conn) ->
        {:error, 400, "InvalidRequest",
         "compress=true / Socket-Encoding: zstd is the /subscribe (v1) opt-in; this endpoint uses zstdDictionary=<id> with the dictionary from getZstdDictionary"}

      true ->
        case List.keyfind(pairs, "zstdDictionary", 0) do
          nil ->
            {:ok, false}

          {_, raw} ->
            current = Wire.dictionary_id(:v2)

            case Integer.parse(raw) do
              {^current, ""} ->
                {:ok, true}

              {n, ""} when n > 0 ->
                {:error, 400, "UnknownZstdDictionary",
                 "unknown zstd dictionary id #{n}; current dictionary id is #{current} (fetch it via getZstdDictionary and reconnect)"}

              _ ->
                {:error, 400, "InvalidRequest",
                 "zstdDictionary must be a positive integer zstd dictionary ID"}
            end
        end
    end
  end

  defp socket_encoding_zstd?(conn),
    do: conn |> get_req_header("socket-encoding") |> Enum.any?(&String.contains?(&1, "zstd"))

  defp filter(pairs, v2?) do
    case if(v2?, do: Filter.v2(pairs), else: Filter.v1(pairs)) do
      {:ok, f} -> {:ok, f}
      {:error, msg} -> {:error, 400, "InvalidRequest", "invalid options: " <> msg}
    end
  end

  defp cursor(pairs, v2?) do
    raw =
      case List.keyfind(pairs, "cursor", 0) do
        {_, v} -> v
        nil -> nil
      end

    case Cursor.resolve(raw, v2?) do
      {:ok, plan} -> {:ok, plan}
      {:error, :invalid} -> {:error, 400, "InvalidRequest", "invalid cursor: #{inspect(raw)}"}
      {:error, {:too_old, msg}} -> {:error, 400, "CursorTooOld", msg}
    end
  end

  defp upgradable(conn) do
    websocket? =
      conn |> get_req_header("upgrade") |> Enum.any?(&(String.downcase(&1) =~ "websocket"))

    cond do
      not websocket? ->
        {:error, 426, "InvalidRequest", "This is an event stream: upgrade to a WebSocket"}

      match?({:error, _}, WebSockAdapter.UpgradeValidation.validate_upgrade(conn)) ->
        {:error, 400, "InvalidRequest", "Invalid WebSocket upgrade"}

      true ->
        :ok
    end
  end

  defp wants_subprotocol?(conn) do
    conn
    |> get_req_header("sec-websocket-protocol")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.any?(&(String.trim(&1) == @subprotocol))
  end

  defp error(conn, false, status, _name, message) do
    conn |> put_resp_content_type("text/plain") |> send_resp(status, message <> "\n") |> halt()
  end

  defp error(conn, true, status, name, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{"error" => name, "message" => message}))
    |> halt()
  end
end
