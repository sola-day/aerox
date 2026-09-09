defmodule AeroxWeb.Plugs.ClientIPTest do
  # Mutates :trusted_proxies in the application env: not async.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias AeroxWeb.Plugs.ClientIP

  setup do
    original = Application.get_env(:aerox, :trusted_proxies)
    on_exit(fn -> Application.put_env(:aerox, :trusted_proxies, original) end)
    :ok
  end

  defp trust(list), do: Application.put_env(:aerox, :trusted_proxies, list)

  defp run(peer, xff \\ nil) do
    conn = %{conn(:get, "/") | remote_ip: peer}
    conn = if xff, do: put_req_header(conn, "x-forwarded-for", xff), else: conn
    ClientIP.call(conn, ClientIP.init([]))
  end

  test "with no trusted proxies the socket address wins, whatever XFF says" do
    trust([])
    assert run({203, 0, 113, 9}, "198.51.100.1").assigns.client_ip == {203, 0, 113, 9}
  end

  test "an untrusted peer's XFF is ignored" do
    trust(["127.0.0.1"])
    assert run({203, 0, 113, 9}, "198.51.100.1").assigns.client_ip == {203, 0, 113, 9}
  end

  test "a trusted peer's XFF is honoured" do
    trust(["127.0.0.1"])
    assert run({127, 0, 0, 1}, "198.51.100.1").assigns.client_ip == {198, 51, 100, 1}
  end

  test "the last untrusted hop is the client (proxies append to XFF)" do
    trust(["127.0.0.1", "10.0.0.0/8"])

    assert run({127, 0, 0, 1}, "1.2.3.4, 198.51.100.1, 10.1.2.3").assigns.client_ip ==
             {198, 51, 100, 1}
  end

  test "CIDR entries match" do
    trust(["172.18.0.0/16"])
    assert run({172, 18, 0, 1}, "198.51.100.1").assigns.client_ip == {198, 51, 100, 1}
    assert run({172, 19, 0, 1}, "198.51.100.1").assigns.client_ip == {172, 19, 0, 1}
  end

  test "IPv6 peers and CIDRs" do
    trust(["fd00::/8"])

    assert run({0xFD00, 0, 0, 0, 0, 0, 0, 1}, "2001:db8::7").assigns.client_ip ==
             {0x2001, 0xDB8, 0, 0, 0, 0, 0, 7}
  end

  test "an IPv4-mapped IPv6 peer matches its IPv4 trusted entry" do
    trust(["127.0.0.1"])

    assert run({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}, "198.51.100.1").assigns.client_ip ==
             {198, 51, 100, 1}
  end

  test "no XFF or a malformed XFF from a trusted peer falls back to the peer" do
    trust(["127.0.0.1"])
    assert run({127, 0, 0, 1}).assigns.client_ip == {127, 0, 0, 1}
    assert run({127, 0, 0, 1}, "not-an-ip").assigns.client_ip == {127, 0, 0, 1}
  end

  test "multiple XFF headers are read in order" do
    trust(["127.0.0.1"])

    conn =
      %{conn(:get, "/") | remote_ip: {127, 0, 0, 1}}
      |> put_req_header("x-forwarded-for", "1.2.3.4")
      |> Map.update!(:req_headers, &(&1 ++ [{"x-forwarded-for", "198.51.100.1"}]))
      |> ClientIP.call([])

    assert conn.assigns.client_ip == {198, 51, 100, 1}
  end

  test "an invalid trusted proxy entry raises" do
    trust(["300.1.1.1"])
    assert_raise ArgumentError, ~r/invalid trusted proxy/, fn -> run({127, 0, 0, 1}) end
  end
end
