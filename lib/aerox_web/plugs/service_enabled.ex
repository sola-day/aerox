defmodule AeroxWeb.Plugs.ServiceEnabled do
  @moduledoc "404 when the owning service is not enabled on this node (DESIGN §2). `plug ServiceEnabled, :plc`."
  import Plug.Conn

  def init(service) when is_atom(service), do: service

  def call(conn, service) do
    if Aerox.Services.enabled?(service) do
      conn
    else
      conn
      |> put_status(404)
      |> Phoenix.Controller.json(%{
        "error" => "NotFound",
        "message" => "service #{service} is not enabled on this node"
      })
      |> halt()
    end
  end
end
