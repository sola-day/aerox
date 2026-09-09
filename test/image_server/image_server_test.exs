defmodule Aerox.ImageServerTest do
  @moduledoc "DESIGN §16: the facade — cache, origin, processing, single-flight, purge."
  use Aerox.ImageServerCase, async: false

  alias Aerox.ImageServer

  @did "did:plc:ewvi7nxzyoun6zhxrhs64oiz"

  defmodule OriginStub do
    @moduledoc "A config-selected origin: answers from a map in the process dictionary of the test."
    def fetch(did, cid) do
      :counters.add(:persistent_term.get({__MODULE__, :counter}), 1, 1)
      Process.sleep(:persistent_term.get({__MODULE__, :delay}, 0))

      case :persistent_term.get({__MODULE__, :blobs}) do
        %{{^did, ^cid} => {:error, reason}} -> {:error, reason}
        %{{^did, ^cid} => bytes} -> {:ok, bytes, "image/png"}
        _ -> {:error, :not_found}
      end
    end
  end

  setup do
    counter = :counters.new(1, [])
    :persistent_term.put({OriginStub, :counter}, counter)
    :persistent_term.put({OriginStub, :delay}, 0)
    source = png(300, 200)
    cid = cid_of(source)
    :persistent_term.put({OriginStub, :blobs}, %{{@did, cid} => source})
    put_config(ImageServer, origin: OriginStub)
    {:ok, cid: cid, counter: counter}
  end

  test "miss fetches, processes and caches; the next call is a hit", %{cid: cid, counter: counter} do
    assert {:ok, path, "image/webp"} = ImageServer.get("avatar", @did, cid, :webp)
    assert path == ImageServer.Cache.path("avatar", @did, cid, :webp)

    assert {:ok, %{width: 1000, height: 1000, loader: "webpload_buffer"}} =
             ImageServer.Processor.info(File.read!(path))

    assert {:ok, ^path, "image/webp"} = ImageServer.get("avatar", @did, cid, "webp")
    assert :counters.get(counter, 1) == 1

    assert {:ok, jpeg_path, "image/jpeg"} = ImageServer.get("feed_fullsize", @did, cid, :jpeg)

    assert {:ok, %{width: 1000, height: 667, loader: "jpegload_buffer"}} =
             ImageServer.Processor.info(File.read!(jpeg_path))

    assert :counters.get(counter, 1) == 2
  end

  test "get_path reports hit or miss", %{cid: cid} do
    assert {:ok, _, "image/webp", :miss} = ImageServer.get_path("/avatar/plain/#{@did}/#{cid}")
    assert {:ok, _, "image/webp", :hit} = ImageServer.get_path("/avatar/plain/#{@did}/#{cid}")

    assert {:ok, _, "image/jpeg", :miss} =
             ImageServer.get_path("/avatar/plain/#{@did}/#{cid}@jpeg")
  end

  test "validation: bad preset/format, invalid did or cid", %{cid: cid} do
    assert {:error, :bad_preset} = ImageServer.get("huge", @did, cid, :webp)
    assert {:error, :bad_format} = ImageServer.get("avatar", @did, cid, "png")
    assert {:error, :bad_path} = ImageServer.get("avatar", "not-a-did", cid, :webp)
    assert {:error, :bad_path} = ImageServer.get("avatar", @did, "../../etc/passwd", :webp)
    assert {:error, :bad_path} = ImageServer.get("avatar", "did:plc:../x", cid, :webp)
    assert {:error, :bad_path} = ImageServer.get_path("/avatar/plain/#{@did}")
    assert {:error, :bad_format} = ImageServer.get_path("/avatar/plain/#{@did}/#{cid}@gif")
  end

  test "origin errors pass through; an undecodable origin body is an upstream error" do
    missing = cid_of("missing")
    assert {:error, :not_found} = ImageServer.get("avatar", @did, missing, :webp)

    down = cid_of("down")
    :persistent_term.put({OriginStub, :blobs}, %{{@did, down} => {:error, :upstream}})
    assert {:error, :upstream} = ImageServer.get("avatar", @did, down, :webp)

    junk = cid_of("junk")
    :persistent_term.put({OriginStub, :blobs}, %{{@did, junk} => "not an image at all"})
    assert {:error, :upstream} = ImageServer.get("avatar", @did, junk, :webp)
    assert ImageServer.Cache.fetch("avatar", @did, junk, :webp) == :miss
  end

  test "concurrent misses for one key make a single origin fetch", %{cid: cid, counter: counter} do
    :persistent_term.put({OriginStub, :delay}, 100)

    results =
      1..25
      |> Task.async_stream(fn _ -> ImageServer.get("avatar", @did, cid, :webp) end,
        max_concurrency: 25,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &match?({:ok, _, "image/webp"}, &1))
    assert :counters.get(counter, 1) == 1
  end

  test "purge drops every rendition so the next get refetches", %{cid: cid, counter: counter} do
    {:ok, _, _} = ImageServer.get("avatar", @did, cid, :webp)
    {:ok, _, _} = ImageServer.get("banner", @did, cid, :jpeg)
    assert ImageServer.purge(@did, cid) == 2
    {:ok, _, _} = ImageServer.get("avatar", @did, cid, :webp)
    assert :counters.get(counter, 1) == 3
  end
end
