defmodule AeroxWeb.Plugs.StreamMethods do
  @moduledoc """
  Event Stream spec, "Connection": a stream endpoint answers a non-`GET`
  request with `405 Method Not Allowed`, as an XRPC JSON error. The routers
  only route `GET` for a subscription, so without this a `POST` falls through
  to the XRPC catch-all and comes back `501`, which tells the client the
  method does not exist at all.

  Which NSIDs are streams is the lexicons' call: every `subscription` def in
  the vendored registry. The `426` for a `GET` without an upgrade is the
  upgrading plug's job (`AeroxWeb.Sockets.Firehose.Plug.upgradable/1`).
  """
  @behaviour Plug
  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "GET"} = conn, _), do: conn

  def call(%Plug.Conn{path_info: ["xrpc", nsid]} = conn, _) do
    if MapSet.member?(subscriptions(), nsid) do
      conn
      |> put_resp_header("allow", "GET")
      |> put_resp_content_type("application/json")
      |> send_resp(
        405,
        Jason.encode!(%{
          "error" => "InvalidRequest",
          "message" => "#{nsid} is an event stream: connect with a GET WebSocket upgrade"
        })
      )
      |> halt()
    else
      conn
    end
  end

  def call(conn, _), do: conn

  @doc "The NSIDs whose main def is a `subscription`."
  def subscriptions do
    case :persistent_term.get({__MODULE__, :subscriptions}, nil) do
      nil ->
        set =
          for %{"id" => id, "defs" => %{"main" => %{"type" => "subscription"}}} <-
                Aerox.ATProto.Lexicon.Vendored.docs(),
              into: MapSet.new(),
              do: id

        :persistent_term.put({__MODULE__, :subscriptions}, set)
        set

      set ->
        set
    end
  end
end
