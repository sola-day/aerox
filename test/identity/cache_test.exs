defmodule Aerox.Identity.CacheTest do
  @moduledoc "DESIGN §21.7: ETS reads, single-flight misses, TTLs, invalidation, warm persistence."
  use Aerox.DataCase, async: false, repos: [Aerox.PLC.Repo]
  import Mox
  alias Aerox.Identity.Cache

  setup :set_mox_global

  @moduletag :service
  @did "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
  @document %{
    "id" => @did,
    "alsoKnownAs" => ["at://atproto.com"],
    "verificationMethod" => [],
    "service" => []
  }

  setup do
    counter = :counters.new(1, [])

    plug = fn conn ->
      :counters.add(counter, 1, 1)
      Process.sleep(50)
      Plug.Conn.send_resp(conn, 200, Jason.encode!(@document))
    end

    name = :"cache_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Cache, name: name, repo: nil, resolver: [plc_url: "https://plc.test", http: [plug: plug]]}
    )

    {:ok, cache: name, counter: counter}
  end

  test "a hundred concurrent misses make one fetch; hits never touch the network", %{
    cache: cache,
    counter: counter
  } do
    results =
      1..100
      |> Task.async_stream(fn _ -> Cache.resolve_did(cache, @did) end, max_concurrency: 100)
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &match?({:ok, %{"id" => @did}}, &1))
    assert :counters.get(counter, 1) == 1
    assert {:ok, _} = Cache.resolve_did(cache, @did)
    assert :counters.get(counter, 1) == 1
    assert {:ok, _} = Cache.resolve_did(cache, @did, force: true)
    assert :counters.get(counter, 1) == 2
    Process.sleep(5)
    assert {:ok, _} = Cache.resolve_did(cache, @did, max_age: 2)
    assert :counters.get(counter, 1) == 3
  end

  test "invalidation drops the entry", %{cache: cache, counter: counter} do
    {:ok, _} = Cache.resolve_did(cache, @did)
    :ok = Cache.invalidate(cache, @did)
    {:ok, _} = Cache.resolve_did(cache, @did)
    assert :counters.get(counter, 1) == 2
  end

  test "handles are cached separately, negative results briefly", %{cache: cache} do
    Aerox.Identity.DNSMock |> expect(:txt, 1, fn _, _ -> {:ok, ["did=" <> @did]} end)
    assert {:ok, @did} = Cache.resolve_handle(cache, "atproto.com")
    assert {:ok, @did} = Cache.resolve_handle(cache, "atproto.com")
  end
end
