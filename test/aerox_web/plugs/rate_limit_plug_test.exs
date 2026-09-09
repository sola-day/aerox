defmodule AeroxWeb.Plugs.RateLimitPlugTest do
  # Shares the ETS table and application env with other tests: not async.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Aerox.RateLimit
  alias AeroxWeb.Plugs.RateLimit, as: Plug_

  defmodule Router do
    use Plug.Router

    plug AeroxWeb.Plugs.ClientIP
    plug :match
    plug :dispatch

    post "/session" do
      conn
      |> AeroxWeb.Plugs.RateLimit.call(AeroxWeb.Plugs.RateLimit.init(:create_session))
      |> respond()
    end

    post "/handle" do
      conn
      |> AeroxWeb.Plugs.RateLimit.call(AeroxWeb.Plugs.RateLimit.init({:update_handle, []}))
      |> respond()
    end

    post "/reset" do
      conn
      |> AeroxWeb.Plugs.RateLimit.call(AeroxWeb.Plugs.RateLimit.init(:reset_password))
      |> respond()
    end

    post "/both" do
      conn
      |> AeroxWeb.Plugs.RateLimit.call(AeroxWeb.Plugs.RateLimit.init(:global_ip))
      |> AeroxWeb.Plugs.RateLimit.call(AeroxWeb.Plugs.RateLimit.init(:reset_password))
      |> respond()
    end

    post "/write" do
      cost = Aerox.RateLimit.write_points(:create)

      case AeroxWeb.Plugs.RateLimit.consume(conn, :repo_write, cost) do
        {:ok, conn} -> send_resp(conn, 200, "ok")
        {:error, conn} -> conn
      end
    end

    defp respond(%{halted: true} = conn), do: conn
    defp respond(conn), do: send_resp(conn, 200, "ok")
  end

  @overrides %{
    global_ip: [%{scale_ms: 60_000, limit: 100, key: :ip}],
    create_session: [%{scale_ms: 60_000, limit: 2, key: :identifier_ip}],
    update_handle: [%{scale_ms: 60_000, limit: 2, key: :did}],
    reset_password: [%{scale_ms: 60_000, limit: 3, key: :ip}],
    repo_write: [%{scale_ms: 60_000, limit: 6, key: :did}]
  }

  setup do
    original = Application.get_env(:aerox, RateLimit)
    Application.put_env(:aerox, RateLimit, overrides: @overrides)
    RateLimit.reset()
    on_exit(fn -> Application.put_env(:aerox, RateLimit, original) end)
    :ok
  end

  # Unique per test so the shared table cannot leak state between tests.
  defp ip do
    n = System.unique_integer([:positive])
    {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}
  end

  defp did, do: "did:plc:#{System.unique_integer([:positive])}"

  defp request(path, opts) do
    conn = %{conn(:post, path, opts[:body] || %{}) | remote_ip: opts[:ip] || ip()}
    conn = if opts[:did], do: assign(conn, :auth, %{did: opts[:did]}), else: conn
    Router.call(conn, Router.init([]))
  end

  defp header(conn, name), do: conn |> get_resp_header(name) |> List.first()

  test "sets the RateLimit-* headers on allowed responses" do
    conn = request("/reset", ip: ip())

    assert conn.status == 200
    assert header(conn, "ratelimit-limit") == "3"
    assert header(conn, "ratelimit-remaining") == "2"
    assert header(conn, "ratelimit-policy") == "3;w=60"
    reset = String.to_integer(header(conn, "ratelimit-reset"))
    assert reset in 1..60
  end

  test "denies with 429, the XRPC error body and Retry-After once the limit is hit" do
    ip = ip()
    for _ <- 1..3, do: assert(request("/reset", ip: ip).status == 200)

    conn = request("/reset", ip: ip)
    assert conn.status == 429
    assert conn.halted
    assert header(conn, "content-type") =~ "application/json"

    assert Jason.decode!(conn.resp_body) == %{
             "error" => "RateLimitExceeded",
             "message" => "Rate Limit Exceeded"
           }

    assert header(conn, "ratelimit-remaining") == "0"
    assert header(conn, "ratelimit-limit") == "3"
    assert String.to_integer(header(conn, "retry-after")) in 1..60
  end

  test "keys by IP: another IP has its own bucket" do
    ip = ip()
    for _ <- 1..3, do: request("/reset", ip: ip)
    assert request("/reset", ip: ip).status == 429
    assert request("/reset", ip: ip()).status == 200
  end

  test "keys by DID when authenticated, sharing across IPs" do
    did = did()
    assert request("/handle", did: did).status == 200
    assert request("/handle", did: did).status == 200
    assert request("/handle", did: did).status == 429
    assert request("/handle", did: did()).status == 200
  end

  test "a :did limit falls back to the IP when unauthenticated" do
    ip = ip()
    assert request("/handle", ip: ip).status == 200
    assert request("/handle", ip: ip).status == 200
    assert request("/handle", ip: ip).status == 429
    assert request("/handle", ip: ip()).status == 200
  end

  test "keys by identifier plus IP for createSession" do
    ip = ip()
    body = %{"identifier" => "alice.test", "password" => "x"}
    assert request("/session", ip: ip, body: body).status == 200
    assert request("/session", ip: ip, body: body).status == 200
    assert request("/session", ip: ip, body: body).status == 429
    # identifier is case-insensitive
    assert request("/session", ip: ip, body: %{body | "identifier" => "ALICE.test"}).status == 429
    # a different identifier from the same IP, and the same identifier from
    # another IP, each get their own bucket
    assert request("/session", ip: ip, body: %{body | "identifier" => "bob.test"}).status == 200
    assert request("/session", ip: ip(), body: body).status == 200
  end

  test "the tightest of several limits is what the headers report" do
    conn = request("/both", ip: ip())
    assert header(conn, "ratelimit-limit") == "3"
    assert header(conn, "ratelimit-remaining") == "2"
  end

  test "consume/3 charges points for handler-side costs" do
    did = did()
    # 6 points, create costs 3: two writes, then denied
    assert request("/write", did: did).status == 200
    conn = request("/write", did: did)
    assert conn.status == 200
    assert header(conn, "ratelimit-remaining") == "0"
    conn = request("/write", did: did)
    assert conn.status == 429
    assert Jason.decode!(conn.resp_body)["error"] == "RateLimitExceeded"
  end

  test "init/1 rejects an unknown limit name" do
    assert_raise ArgumentError, ~r/unknown rate limit/, fn -> Plug_.init(:nope) end
  end

  test "the IP key uses the ClientIP assign when present" do
    ip = ip()
    conn = conn(:post, "/") |> assign(:client_ip, ip)
    assert Plug_.client_ip(conn) == to_string(:inet.ntoa(ip))
  end
end
