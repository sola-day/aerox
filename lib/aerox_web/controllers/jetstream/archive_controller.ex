defmodule AeroxWeb.Jetstream.ArchiveController do
  @moduledoc """
  The Jetstream archive and dictionary endpoints (upstream `internal/xrpcapi`):
  `listSegments`, `getSegment` and `getBlock` (with `ETag`, `Range`,
  conditional requests and HEAD, and a `Cache-Control` lifetime that ends at
  the next compaction plus the grace), `planSnapshot`, `getZstdDictionary`.
  Archive methods answer 503 until the bootstrap has finished.
  """
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  alias Aerox.Jetstream.{Compactor, Config, Manifest, Planner, Segment, Store, Tail, Wire}
  alias AeroxWeb.XRPC.Error

  plug :ready when action in [:list_segments, :get_segment, :get_block, :plan_snapshot]

  defp ready(conn, _) do
    if Store.steady_state?() do
      conn
    else
      AeroxWeb.Plugs.XRPCError.render(conn, %Error{
        status: 503,
        name: "ServiceUnavailable",
        message: "service not ready: bootstrap in progress"
      })
      |> halt()
    end
  end

  # ------------------------------------------------------------ dictionary

  def get_zstd_dictionary(conn, _) do
    id = Wire.dictionary_id(:v2)

    case conn.query_params["id"] do
      nil ->
        dictionary(conn, id)

      raw ->
        case Integer.parse(raw) do
          {^id, ""} ->
            dictionary(conn, id)

          {n, ""} when n > 0 ->
            {:error,
             %Error{
               status: 404,
               name: "DictionaryNotFound",
               message: "no dictionary with id #{n}; current dictionary id is #{id}"
             }}

          {_, ""} ->
            {:error,
             %Error{
               status: 404,
               name: "DictionaryNotFound",
               message: "no dictionary with id #{raw}; current dictionary id is #{id}"
             }}

          _ ->
            {:error, Error.invalid_request("id must be an integer zstd dictionary ID")}
        end
    end
  end

  defp dictionary(conn, id) do
    conn
    |> put_resp_header("etag", ~s("zstd-dict-#{id}"))
    |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
    |> put_resp_header("x-zstd-dictionary-id", Integer.to_string(id))
    |> serve_bytes(Wire.dictionary(:v2))
  end

  # -------------------------------------------------------------- segments

  def list_segments(conn, _) do
    limit =
      case conn.query_params["limit"] do
        nil ->
          {:ok, 100}

        raw ->
          case Integer.parse(raw) do
            {n, ""} when n > 0 ->
              {:ok, min(n, 1000)}

            {_, ""} ->
              {:error, Error.invalid_request("limit must be positive")}

            _ ->
              {:error,
               Error.invalid_request(
                 "Error: Params must have the property \"limit\" as an integer"
               )}
          end
      end

    start =
      case conn.query_params["cursor"] do
        nil ->
          {:ok, 0}

        "" ->
          {:ok, 0}

        raw ->
          case Integer.parse(raw) do
            {n, ""} when n >= 0 -> {:ok, n}
            _ -> {:error, Error.invalid_request("invalid cursor")}
          end
      end

    with {:ok, limit} <- limit, {:ok, start} <- start do
      all = Enum.filter(Manifest.sealed(), &(&1.idx >= start))
      {page, rest} = Enum.split(all, limit)

      body = %{
        "segments" =>
          Enum.map(page, fn s ->
            %{
              "name" => Segment.filename(s.idx),
              "index" => s.idx,
              "sizeBytes" => s.size,
              "checksum" => hex(s.header.checksum),
              "eventCount" => s.header.event_count,
              "minSeq" => s.header.min_seq,
              "maxSeq" => s.header.max_seq,
              "minWitnessedAt" => s.header.min_witnessed_at,
              "maxWitnessedAt" => s.header.max_witnessed_at
            }
          end)
      }

      body =
        if rest != [], do: Map.put(body, "cursor", Integer.to_string(hd(rest).idx)), else: body

      respond(conn, body)
    end
  end

  def get_segment(conn, _) do
    with {:ok, seg} <- segment_param(conn.query_params["name"]) do
      conn
      |> put_resp_header("etag", ~s("#{hex(seg.header.checksum)}"))
      |> put_resp_header("cache-control", cache_control())
      |> serve_file(seg.path, seg.size)
    end
  end

  def get_block(conn, _) do
    with {:ok, seg} <- segment_param(conn.query_params["segment"]),
         {:ok, idx} <- block_index(conn.query_params["blockIndex"]),
         {:ok, info} <-
           (Enum.at(seg.blocks, idx) && {:ok, Enum.at(seg.blocks, idx)}) ||
             {:error,
              %Error{status: 404, name: "BlockNotFound", message: "block index out of range"}},
         {:ok, frame} <-
           (case Tail.read_frame(seg.path, info, seg.header.checksum) do
              {:ok, f} -> {:ok, f}
              _ -> {:error, Error.internal("failed to read block")}
            end) do
      conn
      |> put_resp_header("etag", ~s("#{hex(seg.header.checksum)}:#{idx}"))
      |> put_resp_header("cache-control", cache_control())
      |> serve_bytes(frame)
    end
  end

  defp segment_param(nil),
    do: {:error, Error.invalid_request("Error: Params must have the property \"name\"")}

  defp segment_param(name) do
    with {:ok, idx} <-
           Segment.parse_filename(name) |> ok_or(Error.invalid_request("malformed segment name")),
         {:ok, seg} <-
           Manifest.segment(idx)
           |> ok_or(%Error{status: 404, name: "SegmentNotFound", message: "segment not found"}) do
      {:ok, seg}
    end
  end

  defp block_index(nil),
    do: {:error, Error.invalid_request("Error: Params must have the property \"blockIndex\"")}

  defp block_index(raw) do
    case Integer.parse(raw) do
      {n, ""} when n >= 0 ->
        {:ok, n}

      {_, ""} ->
        {:error, Error.invalid_request("blockIndex must be >= 0")}

      _ ->
        {:error,
         Error.invalid_request(
           "Error: Params must have the property \"blockIndex\" as an integer"
         )}
    end
  end

  # ------------------------------------------------------------------ plan

  def plan_snapshot(conn, _) do
    input = if is_map(conn.body_params), do: Map.drop(conn.body_params, ["_json"]), else: %{}

    case Planner.request(input) do
      {:ok, req} -> respond(conn, Planner.plan(req))
      {:error, msg} -> {:error, Error.invalid_request(msg)}
    end
  end

  # --------------------------------------------------------------- serving

  # upstream cacheLifetime: until the next compaction plus the grace; no-cache otherwise
  defp cache_control do
    case Compactor.next_compaction_at() do
      nil ->
        "public, no-cache"

      at ->
        seconds =
          div(
            DateTime.diff(at, DateTime.utc_now(), :millisecond) +
              Config.compaction_cache_grace_ms(),
            1000
          )

        if seconds > 0, do: "public, max-age=#{seconds}", else: "public, no-cache"
    end
  end

  # http.ServeContent for an in-memory body: If-None-Match, a single Range
  defp serve_bytes(conn, bytes) do
    size = byte_size(bytes)

    serve(conn, size, fn conn, status, offset, length ->
      send_resp(conn, status, binary_part(bytes, offset, length))
    end)
  end

  defp serve_file(conn, path, size) do
    serve(conn, size, fn conn, status, offset, length ->
      send_file(conn, status, path, offset, length)
    end)
  end

  defp serve(conn, size, send) do
    conn =
      conn
      |> put_resp_content_type("application/octet-stream", nil)
      |> put_resp_header("accept-ranges", "bytes")

    etag = conn |> get_resp_header("etag") |> List.first()

    cond do
      etag != nil and
          etag in (conn
                   |> get_req_header("if-none-match")
                   |> Enum.flat_map(&String.split(&1, ","))
                   |> Enum.map(&String.trim/1)) ->
        send_resp(conn, 304, "")

      true ->
        case range(conn, size) do
          :full ->
            send.(conn, 200, 0, size)

          {:partial, first, last} ->
            conn
            |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
            |> send.(206, first, last - first + 1)

          :unsatisfiable ->
            conn |> put_resp_header("content-range", "bytes */#{size}") |> send_resp(416, "")
        end
    end
  end

  defp range(conn, size) do
    if_range = conn |> get_req_header("if-range") |> List.first()
    etag = conn |> get_resp_header("etag") |> List.first()

    with [spec] <- get_req_header(conn, "range"),
         true <- if_range in [nil, etag],
         "bytes=" <> ranges <- spec,
         [one] <- String.split(ranges, ",") do
      case String.split(String.trim(one), "-", parts: 2) do
        ["", suffix] ->
          case Integer.parse(suffix) do
            {n, ""} when n > 0 -> {:partial, max(size - n, 0), size - 1}
            _ -> :full
          end

        [first, last] ->
          with {f, ""} <- Integer.parse(first) do
            l =
              case Integer.parse(last) do
                {l, ""} -> min(l, size - 1)
                _ -> size - 1
              end

            cond do
              f >= size -> :unsatisfiable
              l < f -> :full
              true -> {:partial, f, l}
            end
          else
            _ -> :full
          end
      end
    else
      _ -> :full
    end
  end

  defp hex(checksum),
    do: checksum |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(16, "0")

  defp ok_or({:ok, v}, _), do: {:ok, v}
  defp ok_or(:error, err), do: {:error, err}
end
