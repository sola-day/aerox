defmodule AeroxWeb.Image.Plug do
  @moduledoc """
  The image CDN endpoint (DESIGN §16), mounted with
  `forward "/img", AeroxWeb.Image.Plug`: serves
  `GET /<preset>/plain/<did>/<cid>[@<jpeg|webp>]` relative to the mount, as
  upstream's `bsky/src/image/server.ts`.

  * 200 with `content-type`, `cache-control: public, max-age=31536000`,
    `etag` (cid‖preset‖format) and `x-cache: hit|miss`; 304 on a matching
    `if-none-match`.
  * 400 for a bad path/preset/format or invalid DID/CID, 404 when the blob
    (or its owner) cannot be found, 502 when the origin fails, 503 when the
    processing pool is saturated.
  """
  @behaviour Plug
  import Plug.Conn

  alias Aerox.ImageServer.Presets

  @max_age 31_536_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: method} = conn, _opts) when method in ["GET", "HEAD"] do
    path = "/" <> Enum.join(conn.path_info, "/")

    case Presets.parse_path(path) do
      {:ok, options} ->
        etag = etag(options)

        if fresh?(conn, etag) do
          conn
          |> put_resp_header("cache-control", "public, max-age=#{@max_age}")
          |> put_resp_header("etag", etag)
          |> send_resp(304, "")
          |> halt()
        else
          serve(conn, path, etag)
        end

      {:error, reason} ->
        error(conn, reason)
    end
  end

  def call(conn, _opts), do: error(conn, :method_not_allowed)

  @doc "The strong ETag for a rendition: `\"<cid>::<preset>::<format>\"`."
  def etag(%{cid: cid, preset: preset, format: format}),
    do: ~s("#{cid}::#{preset}::#{Presets.extension(format)}")

  defp fresh?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(&1 == etag or &1 == "*"))
  end

  defp serve(conn, path, etag) do
    case Aerox.ImageServer.get_path(path) do
      {:ok, file, content_type, source} ->
        conn
        |> put_resp_header("content-type", content_type)
        |> put_resp_header("cache-control", "public, max-age=#{@max_age}")
        |> put_resp_header("etag", etag)
        |> put_resp_header("x-cache", Atom.to_string(source))
        |> send_file(200, file)
        |> halt()

      {:error, reason} ->
        error(conn, reason)
    end
  end

  defp error(conn, reason) do
    {status, name, message} =
      case reason do
        :bad_path -> {400, "InvalidRequest", "Invalid path"}
        :bad_preset -> {400, "InvalidRequest", "Invalid path: bad preset"}
        :bad_format -> {400, "InvalidRequest", "Invalid path: bad format"}
        :not_an_image -> {400, "InvalidRequest", "Not an image"}
        :not_found -> {404, "NotFound", "Blob not found"}
        :busy -> {503, "ServiceUnavailable", "Image processing is saturated, retry later"}
        :method_not_allowed -> {405, "MethodNotAllowed", "Method not allowed"}
        _ -> {502, "UpstreamFailure", "Upstream Error"}
      end

    conn
    |> put_resp_header("content-type", "application/json; charset=utf-8")
    |> send_resp(status, Jason.encode!(%{error: name, message: message}))
    |> halt()
  end
end
