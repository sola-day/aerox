defmodule Aerox.ImageServer.CacheTest do
  @moduledoc "DESIGN §16: disk layout, atomic put, LRU sweep, purge."
  use Aerox.ImageServerCase, async: false

  alias Aerox.ImageServer.Cache

  @did "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
  @cid "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku"

  test "the layout is <cache>/<preset>/<did>/<cid>.<fmt> under the configured dir" do
    assert Cache.dir() == "tmp/test-image-cache"

    assert Cache.path("avatar", @did, @cid, :webp) ==
             "tmp/test-image-cache/avatar/#{@did}/#{@cid}.webp"
  end

  test "put then fetch; a miss is :miss; an existing entry is not overwritten" do
    assert Cache.fetch("avatar", @did, @cid, :webp) == :miss
    assert {:ok, path} = Cache.put("avatar", @did, @cid, :webp, "first")
    assert {:ok, ^path} = Cache.fetch("avatar", @did, @cid, :webp)
    assert File.read!(path) == "first"
    assert {:ok, ^path} = Cache.put("avatar", @did, @cid, :webp, "second")
    assert File.read!(path) == "first"
    assert Cache.fetch("avatar", @did, @cid, :jpeg) == :miss
    refute Path.wildcard(Path.dirname(path) <> "/*.tmp-*") != []
  end

  test "an empty file is a miss (upstream treats size 0 as not found)" do
    path = Cache.path("avatar", @did, @cid, :webp)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
    assert Cache.fetch("avatar", @did, @cid, :webp) == :miss
  end

  test "purge removes every preset and format for a blob, nothing else" do
    for preset <- ~w(avatar banner feed_fullsize), format <- [:jpeg, :webp] do
      {:ok, _} = Cache.put(preset, @did, @cid, format, "x")
    end

    other = "bafkreic3dpwntvzs3y5jm3xtnukmsenyfsffwwdt4zuepeivrkcn2ztkhi"
    {:ok, other_path} = Cache.put("avatar", @did, other, :webp, "y")

    assert Cache.purge(@did, @cid) == 6
    assert Cache.fetch("avatar", @did, @cid, :webp) == :miss
    assert Cache.fetch("banner", @did, @cid, :jpeg) == :miss
    assert {:ok, ^other_path} = Cache.fetch("avatar", @did, other, :webp)
    assert Cache.purge(@did, @cid) == 0
  end

  test "sweep evicts least-recently-used first until under the bound" do
    cids =
      for i <- 1..5 do
        cid = cid_of("blob #{i}")
        {:ok, path} = Cache.put("avatar", @did, cid, :webp, String.duplicate("a", 100))
        # older mtimes for earlier entries
        File.touch!(path, System.os_time(:second) - 1000 + i * 10)
        cid
      end

    # a hit refreshes the oldest entry, so it survives
    {:ok, first} = Cache.fetch("avatar", @did, hd(cids), :webp)
    File.touch!(first, System.os_time(:second) + 5)

    assert Cache.size() == 500
    assert {500, remaining, removed} = Cache.sweep(300)
    assert remaining <= 270 and removed >= 3
    assert {:ok, _} = Cache.fetch("avatar", @did, hd(cids), :webp)
    assert Cache.fetch("avatar", @did, Enum.at(cids, 1), :webp) == :miss
    assert Cache.fetch("avatar", @did, Enum.at(cids, 2), :webp) == :miss
    assert {^remaining, ^remaining, 0} = Cache.sweep(300)
  end

  test "the sweeper runs on its interval" do
    {:ok, _} = Cache.put("avatar", @did, @cid, :webp, String.duplicate("a", 100))
    put_config(Aerox.ImageServer, max_bytes: 10)
    start_supervised!({Cache.Sweeper, interval: 20})
    Process.sleep(80)
    assert Cache.fetch("avatar", @did, @cid, :webp) == :miss
  end
end
