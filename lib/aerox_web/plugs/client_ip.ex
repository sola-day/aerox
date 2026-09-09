defmodule AeroxWeb.Plugs.ClientIP do
  @moduledoc """
  Sets `conn.assigns.client_ip` (DESIGN §18.2). `x-forwarded-for` is honoured
  only when the peer (`conn.remote_ip`) is in `config :aerox, :trusted_proxies`
  (plain IPs or CIDRs); then the client is the last hop that is not itself a
  trusted proxy. Otherwise the socket address is used — getting this wrong
  would let anyone pick their bucket, or make every user share one.
  """
  import Plug.Conn

  @type ip :: :inet.ip_address()

  def init(opts), do: opts

  def call(conn, _opts) do
    assign(conn, :client_ip, client_ip(conn))
  end

  @spec client_ip(Plug.Conn.t()) :: ip
  def client_ip(%Plug.Conn{remote_ip: peer} = conn) do
    trusted = trusted_proxies()

    with true <- trusted?(peer, trusted),
         [_ | _] = hops <- forwarded_for(conn),
         {:ok, ip} <- pick_client(hops, trusted) do
      ip
    else
      _ -> peer
    end
  end

  @doc "The configured trusted proxies, parsed to `{ip, prefix_len}`."
  @spec trusted_proxies() :: [{ip, non_neg_integer}]
  def trusted_proxies do
    :aerox
    |> Application.get_env(:trusted_proxies, [])
    |> Enum.flat_map(fn entry ->
      case parse_cidr(entry) do
        {:ok, cidr} -> [cidr]
        :error -> raise ArgumentError, "invalid trusted proxy #{inspect(entry)}"
      end
    end)
  end

  @spec trusted?(ip, [{ip, non_neg_integer}]) :: boolean
  def trusted?(ip, trusted), do: Enum.any?(trusted, &in_cidr?(ip, &1))

  # Rightmost hop first; the first one that is not a trusted proxy is the
  # client. If every hop is trusted, the leftmost is the best we have.
  defp pick_client(hops, trusted) do
    reversed = Enum.reverse(hops)

    case Enum.find(reversed, &(not trusted?(&1, trusted))) do
      nil -> {:ok, List.last(reversed)}
      ip -> {:ok, ip}
    end
  end

  defp forwarded_for(conn) do
    conn
    |> get_req_header("x-forwarded-for")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while([], fn raw, acc ->
      case parse_ip(raw) do
        {:ok, ip} -> {:cont, [ip | acc]}
        # a malformed hop means the header is untrustworthy: use the peer
        :error -> {:halt, []}
      end
    end)
    |> Enum.reverse()
  end

  @doc false
  def parse_ip(raw) when is_binary(raw) do
    case :inet.parse_strict_address(String.to_charlist(raw)) do
      {:ok, ip} -> {:ok, normalize(ip)}
      {:error, _} -> :error
    end
  end

  @doc false
  def parse_cidr(raw) when is_binary(raw) do
    case String.split(raw, "/", parts: 2) do
      [ip] ->
        with {:ok, ip} <- parse_ip(ip), do: {:ok, {ip, bits(ip)}}

      [ip, len] ->
        with {:ok, ip} <- parse_ip(ip),
             {len, ""} <- Integer.parse(len),
             true <- len >= 0 and len <= bits(ip) do
          {:ok, {ip, len}}
        else
          _ -> :error
        end
    end
  end

  def parse_cidr(_), do: :error

  defp in_cidr?(ip, {net, len}) do
    ip = normalize(ip)

    tuple_size(ip) == tuple_size(net) and
      shift(to_int(ip), bits(ip) - len) == shift(to_int(net), bits(net) - len)
  end

  defp shift(int, n), do: Bitwise.bsr(int, n)

  # IPv4-mapped IPv6 (::ffff:a.b.c.d) compares as the IPv4 it wraps.
  defp normalize({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: {Bitwise.bsr(hi, 8), Bitwise.band(hi, 0xFF), Bitwise.bsr(lo, 8), Bitwise.band(lo, 0xFF)}

  defp normalize(ip), do: ip

  defp bits(ip) when tuple_size(ip) == 4, do: 32
  defp bits(ip) when tuple_size(ip) == 8, do: 128

  defp to_int({a, b, c, d}),
    do: Bitwise.bsl(a, 24) + Bitwise.bsl(b, 16) + Bitwise.bsl(c, 8) + d

  defp to_int(ip) when tuple_size(ip) == 8,
    do: ip |> Tuple.to_list() |> Enum.reduce(0, &(Bitwise.bsl(&2, 16) + &1))
end
