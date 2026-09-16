defmodule Aerox.Relay.Hosts do
  @moduledoc "Host rows and the hostname rules of indigo's relay (`host.go`, `ParseHostname`)."
  import Ecto.Query
  alias Aerox.Relay.{Config, Repo}
  alias Aerox.Relay.Schema.{DomainBan, Host}

  @statuses ~w(active idle offline throttled banned)
  def statuses, do: @statuses

  @doc """
  Parses a raw URL or hostname into `{hostname, no_ssl}` as indigo does:
  scheme optional (`http`/`ws` mean no SSL), `localhost` must carry a port,
  anything else must not; no path, query or userinfo.
  """
  @spec parse_hostname(String.t()) :: {:ok, String.t(), boolean} | {:error, String.t()}
  def parse_hostname(raw) when is_binary(raw) do
    raw = String.trim(raw)
    with_scheme = if String.contains?(raw, "://"), do: raw, else: "https://" <> raw

    case URI.new(with_scheme) do
      {:ok, %URI{scheme: scheme, host: host, port: port, path: path, query: q, userinfo: nil}}
      when is_binary(host) and host != "" and scheme in ["http", "https", "ws", "wss"] and
             q in [nil, ""] and path in [nil, "", "/"] ->
        host = String.downcase(host)
        no_ssl = scheme in ["http", "ws"]
        default_port = if no_ssl, do: 80, else: 443

        cond do
          host == "localhost" and port in [nil, default_port] ->
            {:error, "localhost requires an explicit port"}

          host == "localhost" ->
            {:ok, "localhost:#{port}", no_ssl}

          port not in [nil, default_port] ->
            {:error, "hostname must not include a port"}

          not valid_hostname?(host) ->
            {:error, "invalid hostname"}

          true ->
            {:ok, host, no_ssl}
        end

      _ ->
        {:error, "invalid hostname"}
    end
  end

  def parse_hostname(_), do: {:error, "invalid hostname"}

  defp valid_hostname?(host),
    do: Regex.match?(~r/^([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}$/, host)

  @doc "The WebSocket URL of a host's firehose."
  def firehose_url(%Host{hostname: h, no_ssl: no_ssl}, cursor) do
    scheme = if no_ssl, do: "ws", else: "wss"
    base = "#{scheme}://#{h}/xrpc/com.atproto.sync.subscribeRepos"
    if cursor && cursor > 0, do: base <> "?cursor=#{cursor}", else: base
  end

  def http_url(%Host{hostname: h, no_ssl: no_ssl}),
    do: if(no_ssl, do: "http://", else: "https://") <> h

  def trusted?(hostname) do
    Enum.any?(Config.trusted_domains(), fn d ->
      hostname == d or String.ends_with?(hostname, "." <> d)
    end)
  end

  def get(hostname), do: Repo.get_by(Host, hostname: hostname)
  def get_by_id(id), do: Repo.get(Host, id)

  @doc "Hosts by id after `cursor`; `ever_active` keeps only hosts that have received an event."
  def list(cursor \\ 0, limit \\ 200, ever_active \\ true) do
    q = from(h in Host, where: h.id > ^cursor, order_by: [asc: h.id], limit: ^limit)
    q = if ever_active, do: where(q, [h], h.last_seq > 0), else: q
    Repo.all(q)
  end

  def active, do: Repo.all(from(h in Host, where: h.status == "active"))

  @doc "Creates the host row with new-host defaults (indigo `SubscribeToHost`)."
  def create(hostname, no_ssl) do
    trusted = trusted?(hostname)

    %Host{
      hostname: hostname,
      no_ssl: no_ssl,
      trusted: trusted,
      status: "active",
      account_limit:
        if(trusted, do: Config.trusted_account_limit(), else: Config.default_account_limit())
    }
    |> Repo.insert(on_conflict: :nothing, conflict_target: :hostname)
    |> case do
      {:ok, %Host{id: nil}} -> {:ok, get(hostname)}
      other -> other
    end
  end

  def update_status(id, status) when status in @statuses do
    Repo.update_all(from(h in Host, where: h.id == ^id), set: [status: status])
    :ok
  end

  def update_account_limit(id, limit) when is_integer(limit) and limit >= 0 do
    Repo.update_all(from(h in Host, where: h.id == ^id), set: [account_limit: limit])
    :ok
  end

  @doc """
  Persists a host cursor (upstream seq); a host that was `idle` or `offline`
  becomes `active` again, because events are arriving from it.

  A status an operator set (`throttled`, `banned`) is **not** overwritten: the
  consumer persists its cursor on the way out, and resurrecting the row there
  used to leave a host reading `active` with nothing consuming it — invisible,
  and permanent until the next restart re-subscribed every active host.
  """
  def persist_cursor(id, last_seq) when last_seq > 0 do
    now = DateTime.utc_now()

    Repo.update_all(from(h in Host, where: h.id == ^id),
      set: [last_seq: last_seq, last_event_at: now]
    )

    Repo.update_all(from(h in Host, where: h.id == ^id and h.status in ["idle", "offline"]),
      set: [status: "active"]
    )

    :ok
  end

  def persist_cursor(_, _), do: :ok

  @doc "Counts a verification failure; past the threshold the host is paused (`throttled`)."
  def record_error(id) do
    {_, [count]} =
      Repo.update_all(from(h in Host, where: h.id == ^id, select: h.error_count),
        inc: [error_count: 1]
      )

    if count >= Config.max_host_errors() do
      update_status(id, "throttled")
      :paused
    else
      :ok
    end
  end

  def reset_errors(id) do
    Repo.update_all(from(h in Host, where: h.id == ^id), set: [error_count: 0])
    :ok
  end

  def increment_accounts(id) do
    Repo.update_all(from(h in Host, where: h.id == ^id), inc: [account_count: 1])
    :ok
  end

  def domain_banned?(hostname) do
    parts = String.split(hostname, ".")

    candidates =
      for i <- 0..(length(parts) - 2)//1, do: parts |> Enum.drop(i) |> Enum.join(".")

    Repo.exists?(from(b in DomainBan, where: b.domain in ^candidates))
  end

  def ban_domain(domain) do
    Repo.insert!(%DomainBan{domain: domain}, on_conflict: :nothing)
    :ok
  end

  @doc "Hosts admitted through public requestCrawl in the last 24 h."
  def new_hosts_today do
    since = DateTime.add(DateTime.utc_now(), -86_400, :second)
    Repo.aggregate(from(h in Host, where: h.inserted_at > ^since), :count)
  end
end
