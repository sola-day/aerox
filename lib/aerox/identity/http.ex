defmodule Aerox.Identity.HTTP do
  @moduledoc """
  The hardened outbound HTTP client (DESIGN §16, §20.1): every URL's host is
  resolved and checked before connecting — loopback, private, link-local and
  multicast addresses are refused unless `allow_private: true` (the all-in-one
  dev stack, where the PDS *is* on loopback; the exact failure that produced
  "all images 502 while every count reconciles"). No redirects across hosts
  (none at all by default), a body size cap, and a total timeout.

  Tests inject a `plug:` (Req.Test / Bypass); production uses Finch through Req.
  """

  @default_timeout 3_000
  @default_max_bytes 1_000_000

  @type opts :: [
          allow_private: boolean,
          timeout: pos_integer,
          max_bytes: pos_integer,
          headers: [{String.t(), String.t()}],
          plug: term,
          redirect: boolean
        ]

  @doc "GET a URL with the SSRF rules applied. Returns `{:ok, status, headers, body}`."
  @spec get(String.t(), opts) ::
          {:ok, non_neg_integer, [{String.t(), String.t()}], binary} | {:error, term}
  def get(url, opts \\ []), do: request(:get, url, nil, opts)

  @spec post(String.t(), iodata | map, opts) ::
          {:ok, non_neg_integer, [{String.t(), String.t()}], binary} | {:error, term}
  def post(url, body, opts \\ []), do: request(:post, url, body, opts)

  defp request(method, url, body, opts) do
    timeout = Keyword.get(opts, :timeout, config(:timeout, @default_timeout))
    max_bytes = Keyword.get(opts, :max_bytes, @default_max_bytes)

    with {:ok, uri} <- parse(url),
         :ok <-
           check_host(
             uri.host,
             Keyword.get(opts, :allow_private, config(:allow_private, false)),
             opts
           ) do
      req =
        Req.new(
          url: url,
          method: method,
          headers: Keyword.get(opts, :headers, []),
          receive_timeout: timeout,
          connect_options: [timeout: timeout],
          redirect: Keyword.get(opts, :redirect, false),
          retry: false,
          decode_body: false,
          max_retries: 0
        )
        |> then(
          &if(plug = Keyword.get(opts, :plug, config(:plug, nil)),
            do: Req.merge(&1, plug: plug),
            else: &1
          )
        )
        |> then(
          &if(body,
            do: Req.merge(&1, if(is_map(body), do: [json: body], else: [body: body])),
            else: &1
          )
        )

      case Req.request(req) do
        {:ok, %Req.Response{status: status, headers: headers, body: resp_body}}
        when is_binary(resp_body) ->
          if byte_size(resp_body) > max_bytes,
            do: {:error, {:body_too_large, byte_size(resp_body)}},
            else: {:ok, status, flatten_headers(headers), resp_body}

        {:ok, %Req.Response{status: status, headers: headers, body: other}} ->
          {:ok, status, flatten_headers(headers), IO.iodata_to_binary(inspect(other))}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end
  end

  defp parse(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        {:error, {:invalid_url, url}}
    end
  end

  # Resolve the host and refuse non-public addresses. A literal IP is checked
  # directly; a name is looked up and every address must be public.
  @doc false
  def check_host(host, allow_private, opts \\ []) do
    if allow_private do
      :ok
    else
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, ip} ->
          if public_ip?(ip), do: :ok, else: {:error, {:private_address, host}}

        {:error, _} ->
          case lookup(host, opts) do
            {:ok, ips} ->
              if Enum.all?(ips, &public_ip?/1), do: :ok, else: {:error, {:private_address, host}}

            {:error, reason} ->
              {:error, {:dns, reason}}
          end
      end
    end
  end

  defp lookup(host, opts) do
    case Keyword.get(opts, :plug, config(:plug, nil)) do
      # under a test plug no real connection is made; skip the lookup
      nil ->
        case :inet.getaddrs(String.to_charlist(host), :inet) do
          {:ok, ips} -> {:ok, ips}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:ok, [{93, 184, 216, 34}]}
    end
  end

  @doc "True for globally routable IPv4/IPv6 addresses."
  @spec public_ip?(:inet.ip_address()) :: boolean
  def public_ip?({10, _, _, _}), do: false
  def public_ip?({127, _, _, _}), do: false
  def public_ip?({0, _, _, _}), do: false
  def public_ip?({169, 254, _, _}), do: false
  def public_ip?({172, b, _, _}) when b in 16..31, do: false
  def public_ip?({192, 168, _, _}), do: false
  def public_ip?({100, b, _, _}) when b in 64..127, do: false
  def public_ip?({a, _, _, _}) when a >= 224, do: false
  def public_ip?({_, _, _, _}), do: true
  def public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  def public_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: false

  def public_ip?({0, 0, 0, 0, 0, 0xFFFF, a, b}),
    do: public_ip?({div(a, 256), rem(a, 256), div(b, 256), rem(b, 256)})

  def public_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFC00 and a <= 0xFDFF, do: false
  def public_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFE80 and a <= 0xFEBF, do: false
  def public_ip?({a, _, _, _, _, _, _, _}) when a >= 0xFF00, do: false
  def public_ip?(_), do: true

  defp flatten_headers(headers) when is_map(headers),
    do: Enum.flat_map(headers, fn {k, vs} -> Enum.map(List.wrap(vs), &{k, &1}) end)

  defp flatten_headers(headers) when is_list(headers), do: headers

  defp config(key, default),
    do: Keyword.get(Application.get_env(:aerox, __MODULE__, []), key, default)
end
