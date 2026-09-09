defmodule AeroxWeb.XRPC.NotImplementedController do
  @moduledoc "The 501 `MethodNotImplemented` catch-all for `/xrpc/*`, as in xrpc-server."
  use AeroxWeb, :controller

  def call(conn, _params),
    do: AeroxWeb.Plugs.XRPCError.render(conn, AeroxWeb.XRPC.Error.not_implemented())
end
