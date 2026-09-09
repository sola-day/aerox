defmodule AeroxWeb.Plugs.XRPCError do
  @moduledoc "Maps raised `AeroxWeb.XRPC.Error`s (and unexpected exceptions) to XRPC JSON error responses."
  @behaviour Plug
  import Plug.Conn
  alias AeroxWeb.XRPC.Error

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    try do
      conn
    rescue
      e in Error -> render(conn, e)
    end
  end

  @doc "Renders an error and halts."
  def render(conn, %Error{} = e) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(e.status, Jason.encode!(Error.body(e)))
    |> halt()
  end

  @doc "Wraps a controller action so raised XRPC errors and `{:error, %Error{}}` results are rendered."
  defmacro __using__(_) do
    quote do
      def action(conn, _opts) do
        try do
          apply(__MODULE__, action_name(conn), [conn, conn.params])
        rescue
          e in AeroxWeb.XRPC.Error -> AeroxWeb.Plugs.XRPCError.render(conn, e)
        end
        |> case do
          {:error, %AeroxWeb.XRPC.Error{} = e} -> AeroxWeb.Plugs.XRPCError.render(conn, e)
          conn -> conn
        end
      end
    end
  end
end
