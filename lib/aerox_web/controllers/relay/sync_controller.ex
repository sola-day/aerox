defmodule AeroxWeb.Relay.SyncController do
  @moduledoc "`com.atproto.sync.*` as the Relay serves it (indigo `handlers.go`, DESIGN §19)."
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  alias Aerox.Relay.{Accounts, Config, Consumers, HostChecker, Hosts}
  alias Aerox.Relay.Schema.Account
  alias AeroxWeb.XRPC.Error

  def home(conn, _), do: text(conn, "aerox relay (#{Config.hostname()})\n")
  def health(conn, _), do: respond(conn, %{"status" => "ok"})

  def did_json(conn, _) do
    respond(conn, %{
      "@context" => ["https://www.w3.org/ns/did/v1"],
      "id" => Config.service_did(),
      "service" => [
        %{
          "id" => "#bsky_relay",
          "type" => "AtprotoRelay",
          "serviceEndpoint" => Config.public_url()
        }
      ]
    })
  end

  defp admin!(conn),
    do: conn.assigns[:relay_admin?] || raise(Error.auth_required("admin authentication required"))

  # -------------------------------------------------------------- requestCrawl

  def request_crawl(conn, _) do
    admin = conn.assigns[:relay_admin?] == true

    raw =
      conn.body_params["hostname"] ||
        raise(Error.invalid_request("hostname field empty or invalid: "))

    {hostname, no_ssl} =
      case Hosts.parse_hostname(raw) do
        {:ok, h, no_ssl} ->
          {h, no_ssl}

        {:error, _} ->
          raise Error.invalid_request("hostname field empty or invalid: #{raw}", "BadRequest")
      end

    if no_ssl and not Config.allow_insecure_hosts?() and not admin,
      do: raise(Error.invalid_request("this relay requires host SSL", "BadRequest"))

    if String.starts_with?(hostname, "localhost:") and not admin,
      do:
        raise(
          Error.invalid_request("can not configure localhost via public endpoint", "BadRequest")
        )

    if Hosts.domain_banned?(hostname),
      do: raise(Error.auth_required("host domain is banned", "DomainBan"))

    url = if(no_ssl, do: "http://", else: "https://") <> hostname

    case HostChecker.check_host(url) do
      :ok ->
        :ok

      {:error, msg} ->
        raise Error.invalid_request("host server unreachable: #{msg}", "HostNotFound")
    end

    subscribe(hostname, no_ssl, admin)
    send_resp(conn, 200, "")
  end

  defp subscribe(hostname, no_ssl, admin) do
    if Consumers.subscribed?(hostname) do
      :ok
    else
      host =
        case Hosts.get(hostname) do
          nil ->
            if not admin and Hosts.new_hosts_today() >= Config.new_hosts_per_day(),
              do: raise(Error.invalid_request("new hosts disabled for now", "NewHostsDisabled"))

            {:ok, host} = Hosts.create(hostname, no_ssl)
            host

          %{status: "banned"} ->
            raise Error.auth_required("cannot subscribe to banned pds", "DomainBan")

          host ->
            host
        end

      Consumers.subscribe(host)
    end
  end

  # ------------------------------------------------------------------ hosts

  def list_hosts(conn, _) do
    params = params!(conn, "com.atproto.sync.listHosts")
    limit = params["limit"] || 200
    cursor = parse_cursor(params["cursor"])
    hosts = Hosts.list(cursor, limit, true)

    body = %{"hosts" => Enum.map(hosts, &host_view/1)}

    body =
      if length(hosts) >= limit and length(hosts) > 1,
        do: Map.put(body, "cursor", to_string(List.last(hosts).id)),
        else: body

    respond(conn, body)
  end

  def get_host_status(conn, _) do
    params = params!(conn, "com.atproto.sync.getHostStatus")

    host =
      Hosts.get(params["hostname"]) || raise(Error.not_found("host not found", "HostNotFound"))

    respond(conn, host_view(host))
  end

  defp host_view(h),
    do: %{
      "hostname" => h.hostname,
      "seq" => h.last_seq,
      "status" => h.status,
      "accountCount" => h.account_count
    }

  # ------------------------------------------------------------------ repos

  def list_repos(conn, _) do
    params = params!(conn, "com.atproto.sync.listRepos")
    limit = params["limit"] || 500
    cursor = parse_cursor(params["cursor"])
    rows = Accounts.list_detailed(cursor, limit)

    repos =
      for {acc, repo} <- rows do
        %{
          "did" => acc.did,
          "head" => repo && repo.commit_cid,
          "rev" => repo && repo.rev,
          "active" => Account.active?(acc)
        }
        |> then(&if(s = Account.status_field(acc), do: Map.put(&1, "status", s), else: &1))
        |> Enum.reject(fn {_, v} -> is_nil(v) end)
        |> Map.new()
      end

    body = %{"repos" => repos}

    body =
      if length(rows) >= limit and length(rows) > 1,
        do: Map.put(body, "cursor", to_string(elem(List.last(rows), 0).uid)),
        else: body

    respond(conn, body)
  end

  def get_repo_status(conn, _) do
    params = params!(conn, "com.atproto.sync.getRepoStatus")

    acc =
      Accounts.get(params["did"]) || raise(Error.not_found("account not found", "RepoNotFound"))

    repo = Accounts.get_repo(acc.uid)

    body = %{"did" => acc.did, "active" => Account.active?(acc)}
    body = if s = Account.status_field(acc), do: Map.put(body, "status", s), else: body
    body = if repo, do: Map.put(body, "rev", repo.rev), else: body
    respond(conn, body)
  end

  def get_latest_commit(conn, _) do
    params = params!(conn, "com.atproto.sync.getLatestCommit")

    acc =
      Accounts.get(params["did"]) || raise(Error.not_found("account not found", "RepoNotFound"))

    case Account.status_field(acc) do
      nil ->
        :ok

      s when s in ["takendown", "suspended"] ->
        raise Error.forbidden("account not active (takendown)", "RepoTakendown")

      "deactivated" ->
        raise Error.forbidden("account not active (deactivated)", "RepoDeactivated")

      "deleted" ->
        raise Error.forbidden("account not active (deleted)", "RepoDeleted")

      s ->
        raise Error.forbidden("account not active: #{s}", "RepoInactive")
    end

    repo =
      Accounts.get_repo(acc.uid) ||
        raise(
          Error.not_found("do not know current repo state for account", "RepoNotSynchronized")
        )

    respond(conn, %{"cid" => repo.commit_cid, "rev" => repo.rev})
  end

  # DESIGN §19: non-archival. Repo content is the hosting PDS's to serve, so
  # the repo-content methods redirect there, query intact — the Sync spec's
  # "the upstream may instead simply use an HTTP redirect to the PDS instance",
  # and what indigo does for getRepo. Unlike indigo, an account this relay has
  # taken down is refused here rather than redirected.
  def redirect_to_pds(conn, _) do
    did = conn.query_params["did"]
    acc = is_binary(did) && Accounts.get(did)

    host =
      with %Account{} <- acc,
           %{} = host <- Hosts.get_by_id(acc.host_id),
           do: host,
           else: (_ -> nil)

    cond do
      is_nil(host) ->
        {:error, Error.not_found("Could not find repo for DID: #{did}", "RepoNotFound")}

      Account.status_field(acc) in ["takendown", "suspended"] ->
        {:error, Error.forbidden("Repo has been takendown: #{did}", "RepoTakendown")}

      true ->
        location =
          Hosts.http_url(host) <>
            conn.request_path <>
            if(conn.query_string == "", do: "", else: "?" <> conn.query_string)

        conn
        |> put_resp_header("location", location)
        |> send_resp(302, "")
    end
  end

  def not_implemented(_conn, _), do: {:error, Error.not_implemented()}

  # ------------------------------------------------------------------ admin

  def admin_subscribe_host(conn, _) do
    admin!(conn)
    raw = conn.body_params["hostname"] || raise(Error.invalid_request("hostname required"))

    case Hosts.parse_hostname(raw) do
      {:ok, hostname, no_ssl} ->
        subscribe(hostname, no_ssl, true)
        send_resp(conn, 200, "")

      {:error, msg} ->
        raise Error.invalid_request(msg)
    end
  end

  def admin_set_account_limit(conn, _) do
    admin!(conn)

    host =
      Hosts.get(conn.body_params["hostname"] || "") ||
        raise(Error.not_found("host not found", "HostNotFound"))

    limit = conn.body_params["accountLimit"]

    if not is_integer(limit) or limit < 0,
      do: raise(Error.invalid_request("accountLimit must be a non-negative integer"))

    Hosts.update_account_limit(host.id, limit)
    send_resp(conn, 200, "")
  end

  def admin_ban_domain(conn, _) do
    admin!(conn)
    domain = conn.body_params["domain"] || raise(Error.invalid_request("domain required"))
    Hosts.ban_domain(String.downcase(domain))
    send_resp(conn, 200, "")
  end

  def admin_set_host_status(conn, _) do
    admin!(conn)

    host =
      Hosts.get(conn.body_params["hostname"] || "") ||
        raise(Error.not_found("host not found", "HostNotFound"))

    status = conn.body_params["status"]
    if status not in Hosts.statuses(), do: raise(Error.invalid_request("invalid status"))
    Hosts.update_status(host.id, status)
    if status != "active", do: Consumers.unsubscribe(host.hostname)
    if status == "active", do: Consumers.subscribe(%{host | status: "active"})
    send_resp(conn, 200, "")
  end

  defp parse_cursor(nil), do: 0

  defp parse_cursor(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 -> n
      _ -> raise Error.invalid_request("invalid cursor")
    end
  end
end
