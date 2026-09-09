defmodule AeroxWeb.Plugs.CORS do
  @moduledoc """
  Upstream's `cors()` on the PDS (`packages/pds/src/index.ts`): any origin
  may call the XRPC, well-known and image endpoints from a browser. Exposes
  the headers clients read (`DPoP-Nonce`, `WWW-Authenticate`, the rate-limit
  and `atproto-*` headers) and answers preflights with 204.
  """
  import Plug.Conn

  @expose ~w(DPoP-Nonce WWW-Authenticate atproto-repo-rev atproto-content-labelers ratelimit-limit ratelimit-remaining ratelimit-reset ratelimit-policy retry-after)

  def init(opts), do: opts

  def call(conn, _opts) do
    conn =
      conn
      |> put_resp_header("access-control-allow-origin", "*")
      |> put_resp_header("access-control-allow-methods", "GET, POST, OPTIONS")
      |> put_resp_header(
        "access-control-allow-headers",
        "authorization, content-type, dpop, atproto-proxy, atproto-accept-labelers, x-bsky-topics, accept-language, content-language"
      )
      |> put_resp_header("access-control-expose-headers", Enum.join(@expose, ", "))
      |> put_resp_header("access-control-max-age", "86400")

    if conn.method == "OPTIONS", do: conn |> send_resp(204, "") |> halt(), else: conn
  end
end
