defmodule AeroxWeb.Image.PlugTest do
  @moduledoc """
  DESIGN §16 end to end: the plug → facade → real Origin (DID document through
  an identity cache, `com.atproto.sync.getBlob` on the resolved PDS through
  `Aerox.Identity.HTTP`'s test plug) → libvips → disk cache → headers.
  """
  use Aerox.ImageServerCase, async: false
  import Plug.Test
  import Plug.Conn

  alias AeroxWeb.Image.Plug, as: ImagePlug

  @did "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
  @pds "https://pds.test"

  setup do
    source = jpeg(300, 200, 6)
    cid = cid_of(source)
    blobs = %{cid => source, cid_of("wrong bytes") => "these bytes do not hash to the cid"}

    doc = %{
      "id" => @did,
      "alsoKnownAs" => ["at://alice.test"],
      "verificationMethod" => [],
      "service" => [
        %{
          "id" => "#atproto_pds",
          "type" => "AtprotoPersonalDataServer",
          "serviceEndpoint" => @pds
        }
      ]
    }

    plc_plug = fn conn -> send_resp(conn, 200, Jason.encode!(doc)) end
    blob_calls = :counters.new(1, [])

    pds_plug = fn conn ->
      :counters.add(blob_calls, 1, 1)
      conn = fetch_query_params(conn)
      assert conn.request_path == "/xrpc/com.atproto.sync.getBlob"
      assert conn.host == "pds.test"
      assert conn.query_params["did"] == @did

      case Map.fetch(blobs, conn.query_params["cid"]) do
        {:ok, "these bytes" <> _ = bytes} ->
          conn |> put_resp_content_type("image/jpeg") |> send_resp(200, bytes)

        {:ok, bytes} ->
          conn |> put_resp_content_type("image/jpeg") |> send_resp(200, bytes)

        :error ->
          case conn.query_params["cid"] do
            "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku" ->
              conn |> put_resp_content_type("text/html") |> send_resp(200, "<html/>")

            "bafkreic3dpwntvzs3y5jm3xtnukmsenyfsffwwdt4zuepeivrkcn2ztkhi" ->
              send_resp(conn, 500, "boom")

            _ ->
              conn
              |> put_resp_content_type("application/json")
              |> send_resp(404, ~s({"error":"BlobNotFound","message":"Blob not found"}))
          end
      end
    end

    cache = :"image_identity_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Aerox.Identity.Cache,
       name: cache, repo: nil, resolver: [plc_url: "https://plc.test", http: [plug: plc_plug]]}
    )

    put_config(Aerox.ImageServer.Origin, identity_cache: cache, http: [plug: pds_plug])
    {:ok, cid: cid, blob_calls: blob_calls}
  end

  defp request(path, headers \\ []) do
    Enum.reduce(headers, conn(:get, path), fn {k, v}, c -> put_req_header(c, k, v) end)
    |> ImagePlug.call([])
  end

  test "serves a processed rendition with upstream's headers, then from cache", %{
    cid: cid,
    blob_calls: calls
  } do
    conn = request("/avatar/plain/#{@did}/#{cid}@jpeg")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000"]
    assert get_resp_header(conn, "etag") == [~s("#{cid}::avatar::jpeg")]
    assert get_resp_header(conn, "x-cache") == ["miss"]

    assert {:ok, %{width: 1000, height: 1000, loader: "jpegload_buffer"}} =
             Aerox.ImageServer.Processor.info(conn.resp_body)

    conn = request("/avatar/plain/#{@did}/#{cid}@jpeg")
    assert conn.status == 200
    assert get_resp_header(conn, "x-cache") == ["hit"]
    assert :counters.get(calls, 1) == 1

    conn = request("/feed_fullsize/plain/#{@did}/#{cid}")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/webp"]
    assert get_resp_header(conn, "etag") == [~s("#{cid}::feed_fullsize::webp")]
    assert {:ok, %{width: 667, height: 1000}} = Aerox.ImageServer.Processor.info(conn.resp_body)
  end

  test "304 on a matching if-none-match, without touching the origin", %{
    cid: cid,
    blob_calls: calls
  } do
    etag = ~s("#{cid}::banner::webp")
    conn = request("/banner/plain/#{@did}/#{cid}", [{"if-none-match", etag}])
    assert conn.status == 304
    assert conn.resp_body == ""
    assert get_resp_header(conn, "etag") == [etag]
    assert :counters.get(calls, 1) == 0

    conn = request("/banner/plain/#{@did}/#{cid}", [{"if-none-match", ~s|"other", | <> etag}])
    assert conn.status == 304

    conn = request("/banner/plain/#{@did}/#{cid}", [{"if-none-match", ~s("stale")}])
    assert conn.status == 200
  end

  test "400 for bad paths, presets, formats and invalid identifiers", %{cid: cid} do
    assert %{status: 400} = conn = request("/avatar/#{@did}/#{cid}")
    assert Jason.decode!(conn.resp_body)["error"] == "InvalidRequest"
    assert %{status: 400} = request("/thumb/plain/#{@did}/#{cid}")
    assert %{status: 400} = request("/avatar/plain/#{@did}/#{cid}@gif")
    assert %{status: 400} = request("/avatar/plain/nobody/#{cid}")
    assert %{status: 400} = request("/avatar/plain/#{@did}/not-a-cid")
    assert %{status: 400} = request("/")
  end

  test "404 when the origin has no such blob, the CID does not verify, or the DID has no PDS" do
    assert %{status: 404} = conn = request("/avatar/plain/#{@did}/#{cid_of("missing")}")

    assert Jason.decode!(conn.resp_body) == %{
             "error" => "NotFound",
             "message" => "Blob not found"
           }

    assert %{status: 404} = request("/avatar/plain/#{@did}/#{cid_of("wrong bytes")}")

    assert %{status: 404} =
             request("/avatar/plain/did:plc:aaaaaaaaaaaaaaaaaaaaaaaa/#{cid_of("x")}")
  end

  test "400 when the origin says it is not an image; 502 when the origin fails" do
    assert %{status: 400} =
             conn =
             request(
               "/avatar/plain/#{@did}/bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"
             )

    assert Jason.decode!(conn.resp_body)["message"] == "Not an image"

    assert %{status: 502} =
             conn =
             request(
               "/avatar/plain/#{@did}/bafkreic3dpwntvzs3y5jm3xtnukmsenyfsffwwdt4zuepeivrkcn2ztkhi"
             )

    assert Jason.decode!(conn.resp_body)["error"] == "UpstreamFailure"
  end

  test "only GET and HEAD", %{cid: cid} do
    assert %{status: 405} = conn(:post, "/avatar/plain/#{@did}/#{cid}") |> ImagePlug.call([])
  end
end
