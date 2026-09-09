defmodule AeroxWeb.PDS.ProxyController do
  @moduledoc """
  Upstream `pipethrough` (DESIGN §11.1): any `/xrpc/<nsid>` the PDS does not
  serve itself is forwarded to the `atproto-proxy: <did>#<serviceId>` target
  or, failing that, to the default service for the NSID (the configured
  AppView for `app.bsky.*`, the chat service for `chat.bsky.*`, the mod
  service for `tools.ozone.*`), with a service JWT signed by the caller's
  repo signing key (`iss` = caller, `aud` = target DID, `lxm` = NSID).
  Unauthenticated calls are forwarded without an `authorization` header.
  With no target the answer is 501 `MethodNotImplemented`, as in xrpc-server.
  """
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  alias Aerox.Auth.ServiceJWT
  alias Aerox.Identity.HTTP
  alias Aerox.PDS.{Accounts, Config, Sessions}
  alias AeroxWeb.XRPC.Error

  @protected ~w(
    com.atproto.admin.sendEmail com.atproto.identity.requestPlcOperationSignature
    com.atproto.identity.signPlcOperation com.atproto.identity.updateHandle
    com.atproto.server.activateAccount com.atproto.server.confirmEmail
    com.atproto.server.createAppPassword com.atproto.server.deactivateAccount
    com.atproto.server.getAccountInviteCodes com.atproto.server.getSession
    com.atproto.server.listAppPasswords com.atproto.server.requestAccountDelete
    com.atproto.server.requestEmailConfirmation com.atproto.server.requestEmailUpdate
    com.atproto.server.revokeAppPassword com.atproto.server.updateEmail
  )
  @req_headers ~w(accept-language atproto-accept-labelers x-bsky-topics)
  @res_headers ~w(content-type content-length atproto-repo-rev atproto-content-labelers retry-after)

  def proxy(conn, _params) do
    lxm = AeroxWeb.XRPC.nsid(conn)

    if conn.method not in ["GET", "POST"],
      do: raise(Error.invalid_request("XRPC requests only supports GET and POST"))

    if String.downcase(lxm) in @protected,
      do: raise(Error.invalid_request("Bad token method", "InvalidToken"))

    case target(conn, lxm) do
      nil ->
        {:error, Error.not_implemented()}

      {did, url} ->
        auth = authorization(conn, did, lxm)
        forward(conn, url, lxm, auth)
    end
  end

  # -- target ---------------------------------------------------------------

  defp target(conn, lxm) do
    case get_req_header(conn, "atproto-proxy") do
      [header | _] -> parse_proxy_header(header)
      [] -> default_service(lxm)
    end
  end

  defp parse_proxy_header(header) do
    case String.split(header, "#") do
      ["", _] ->
        raise Error.invalid_request("no did specified in proxy header")

      [_, ""] ->
        raise Error.invalid_request("no service id specified in proxy header")

      [did, service_id] ->
        if String.contains?(header, " "),
          do: raise(Error.invalid_request("proxy header cannot contain spaces"))

        configured = configured_services()

        case Enum.find(configured, fn {_, svc} ->
               svc[:did] == did and svc[:service_id] == service_id
             end) do
          {_, svc} -> {did, svc[:url]}
          nil -> resolve_service(did, service_id)
        end

      [_] ->
        raise Error.invalid_request("no service id specified in proxy header")

      _ ->
        raise Error.invalid_request("invalid proxy header format")
    end
  end

  defp resolve_service(did, service_id) do
    case Aerox.Identity.resolve_did(Aerox.PDS.Identity, did) do
      {:ok, doc} ->
        case Aerox.ATProto.Identity.service_endpoint(doc, "#" <> service_id) do
          nil -> raise Error.invalid_request("could not resolve proxy did service url")
          url -> {did, url}
        end

      {:error, _} ->
        raise Error.invalid_request("could not resolve proxy did")
    end
  end

  defp configured_services do
    for {key, service_id} <- [
          appview: "bsky_appview",
          chat: "bsky_chat",
          mod_service: "atproto_labeler"
        ],
        svc = Config.get(key),
        (is_list(svc) and svc[:url]) && svc[:did] do
      {key, Keyword.put(svc, :service_id, service_id)}
    end
  end

  defp default_service(lxm) do
    key =
      cond do
        String.starts_with?(lxm, "tools.ozone.") -> :mod_service
        String.starts_with?(lxm, "chat.bsky.") -> :chat
        String.starts_with?(lxm, "app.bsky.") -> :appview
        true -> nil
      end

    case key && configured_services()[key] do
      nil -> nil
      svc -> {svc[:did], svc[:url]}
    end
  end

  # -- auth -----------------------------------------------------------------

  defp authorization(conn, aud, lxm) do
    case conn.assigns[:auth] do
      %{type: :access, did: did, scope: scope} ->
        privileged =
          String.starts_with?(lxm, "chat.bsky.") or lxm == "com.atproto.server.createAccount"

        if privileged and scope not in Sessions.access_privileged(),
          do: raise(Error.invalid_request("Bad token method", "InvalidToken"))

        keypair = Accounts.signing_keypair(did) || raise(Error.auth_required("Account not found"))
        {:ok, jwt} = {:ok, ServiceJWT.create(keypair: keypair, iss: did, aud: aud, lxm: lxm)}
        [{"authorization", "Bearer " <> jwt}]

      %{type: :service} ->
        raise Error.invalid_request("Bad token method", "InvalidToken")

      _ ->
        []
    end
  end

  # -- forward --------------------------------------------------------------

  defp forward(conn, origin, _lxm, auth_headers) do
    url =
      origin <>
        conn.request_path <> if(conn.query_string == "", do: "", else: "?" <> conn.query_string)

    headers =
      for name <- @req_headers, [v | _] <- [get_req_header(conn, name)], do: {name, v}

    headers = headers ++ auth_headers ++ [{"accept-encoding", "identity"}]

    # `plug: nil` overrides the test-only Endpoint plug on Aerox.Identity.HTTP;
    # a proxied request must go over the network, or it would loop back here.
    http_opts = [
      headers: headers,
      allow_private: true,
      timeout: 30_000,
      max_bytes: 50 * 1024 * 1024,
      plug: Config.get(:proxy_plug)
    ]

    result =
      case conn.method do
        "GET" ->
          HTTP.get(url, http_opts)

        "POST" ->
          body = IO.iodata_to_binary(conn.assigns[:raw_body] || [])

          http_opts =
            case get_req_header(conn, "content-type") do
              [ct | _] -> Keyword.update!(http_opts, :headers, &[{"content-type", ct} | &1])
              [] -> http_opts
            end

          HTTP.post(url, body, http_opts)
      end

    case result do
      {:ok, status, resp_headers, body} ->
        conn =
          Enum.reduce(resp_headers, conn, fn {k, v}, c ->
            if String.downcase(k) in @res_headers and String.downcase(k) != "content-length",
              do: put_resp_header(c, String.downcase(k), v),
              else: c
          end)

        send_resp(conn, status, body)

      {:error, reason} ->
        require Logger
        Logger.warning("xrpc proxy failed: #{inspect(reason)}")
        {:error, Error.upstream_failure("Upstream service unreachable")}
    end
  end
end
