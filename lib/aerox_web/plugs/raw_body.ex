defmodule AeroxWeb.Plugs.RawBody do
  @moduledoc """
  `Plug.Parsers` body reader that keeps the raw bytes of `/xrpc/*` requests in
  `conn.assigns.raw_body`, so the proxy (DESIGN §11.1) can forward a body
  verbatim after the JSON parser consumed it. Other paths are read normally.
  """
  def read_body(%Plug.Conn{path_info: ["xrpc" | _]} = conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, append(conn, body)}
      {:more, body, conn} -> {:more, body, append(conn, body)}
      other -> other
    end
  end

  def read_body(conn, opts), do: Plug.Conn.read_body(conn, opts)

  defp append(conn, chunk) do
    Plug.Conn.assign(conn, :raw_body, [conn.assigns[:raw_body] || [], chunk])
  end
end
