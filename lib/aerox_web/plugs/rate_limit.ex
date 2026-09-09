defmodule AeroxWeb.Plugs.RateLimit do
  @moduledoc """
  Route-level rate limiting over `Aerox.RateLimit` (DESIGN §18.2).

      plug AeroxWeb.Plugs.RateLimit, :create_session
      plug AeroxWeb.Plugs.RateLimit, {:global_ip, []}
      plug AeroxWeb.Plugs.RateLimit, {:upload_blob, key: :did, cost: 1}

  Options: `:key` overrides the limit's key kind (`:ip | :did | :identifier_ip`
  or a `conn -> term` function); `:cost` is the points per hit (default 1).

  Keys: `:ip` is `conn.assigns.client_ip` (set by `AeroxWeb.Plugs.ClientIP`)
  falling back to `conn.remote_ip`; `:did` is `conn.assigns.auth.did`, falling
  back to the IP when unauthenticated; `:identifier_ip` is the `identifier`
  body param plus the IP (upstream's createSession key).

  Every response carries `RateLimit-Limit`, `RateLimit-Remaining`,
  `RateLimit-Reset` (delta seconds, per draft-ietf-httpapi-ratelimit-headers)
  and `RateLimit-Policy` (`limit;w=window-seconds`). When several limits apply
  to one request the tightest one is reported. A denied request gets 429 with
  the XRPC `RateLimitExceeded` error and is halted.

  Points-based limits whose cost is only known inside the handler call
  `consume/3` instead:

      case AeroxWeb.Plugs.RateLimit.consume(conn, :repo_write, 3) do
        {:ok, conn} -> ...
        {:error, conn} -> conn   # already 429'd and halted
      end
  """
  import Plug.Conn

  alias Aerox.RateLimit

  @type key_kind :: RateLimit.key_kind() | (Plug.Conn.t() -> term)

  def init(name) when is_atom(name), do: init({name, []})

  def init({name, opts}) when is_atom(name) and is_list(opts) do
    # Fails loudly at init when the name is unknown (compile time in prod).
    _ = RateLimit.fetch_limit!(name)
    {name, opts}
  end

  def call(conn, {name, opts}) do
    case consume(conn, name, Keyword.get(opts, :cost, 1), opts) do
      {:ok, conn} -> conn
      {:error, conn} -> conn
    end
  end

  @doc """
  Charge `cost` points against `name` for this conn. `{:ok, conn}` with the
  headers set, or `{:error, conn}` already answered 429 and halted.
  """
  @spec consume(Plug.Conn.t(), RateLimit.name(), pos_integer, keyword) ::
          {:ok, Plug.Conn.t()} | {:error, Plug.Conn.t()}
  def consume(conn, name, cost, opts \\ []) do
    kind = Keyword.get_lazy(opts, :key, fn -> key_kind(name) end)
    subject = subject(conn, kind)

    case RateLimit.hit_named(name, subject, cost) do
      {:allow, status} ->
        {:ok, put_status_headers(conn, status)}

      {:deny, status} ->
        conn =
          conn
          |> put_status_headers(status)
          |> put_resp_header("retry-after", Integer.to_string(seconds(status.reset_ms)))
          |> put_resp_content_type("application/json")
          |> send_resp(
            429,
            Jason.encode!(%{"error" => "RateLimitExceeded", "message" => "Rate Limit Exceeded"})
          )
          |> halt()

        {:error, conn}
    end
  end

  @doc "The client IP as a string, for keys and logs."
  @spec client_ip(Plug.Conn.t()) :: String.t()
  def client_ip(conn) do
    (conn.assigns[:client_ip] || conn.remote_ip) |> :inet.ntoa() |> to_string()
  end

  defp key_kind(name) do
    name |> RateLimit.fetch_limit!() |> hd() |> Map.fetch!(:key)
  end

  defp subject(conn, :ip), do: {:ip, client_ip(conn)}

  defp subject(conn, :did) do
    case conn.assigns[:auth] do
      %{did: did} when is_binary(did) -> {:did, did}
      _ -> subject(conn, :ip)
    end
  end

  defp subject(conn, :identifier_ip) do
    {:identifier_ip, identifier(conn), client_ip(conn)}
  end

  defp subject(conn, fun) when is_function(fun, 1), do: fun.(conn)

  defp identifier(conn) do
    params =
      case conn.body_params do
        %Plug.Conn.Unfetched{} -> conn.params
        body -> body
      end

    case params do
      %{"identifier" => id} when is_binary(id) -> String.downcase(id)
      _ -> ""
    end
  end

  # Keep the tightest status across every limit applied to this request.
  defp put_status_headers(conn, status) do
    status =
      case conn.private[:aerox_rate_limit] do
        %{remaining: r} = prev when r < status.remaining -> prev
        _ -> status
      end

    conn
    |> put_private(:aerox_rate_limit, status)
    |> put_resp_header("ratelimit-limit", Integer.to_string(status.limit))
    |> put_resp_header("ratelimit-remaining", Integer.to_string(status.remaining))
    |> put_resp_header("ratelimit-reset", Integer.to_string(seconds(status.reset_ms)))
    |> put_resp_header(
      "ratelimit-policy",
      "#{status.limit};w=#{div(status.scale_ms, 1000)}"
    )
  end

  defp seconds(ms), do: div(ms + 999, 1000)
end
