defmodule AeroxWeb.Jetstream.MetaController do
  @moduledoc false
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  alias AeroxWeb.XRPC.Error

  def home(conn, _) do
    text(conn, """
    This is an AT Protocol Jetstream service (aerox).

    Live JSON firehose:  wss://#{Aerox.Jetstream.Config.hostname()}/subscribe
    Stream (v2):         wss://#{Aerox.Jetstream.Config.hostname()}/xrpc/network.bsky.jetstream.subscribeEvents
    Archive:             /xrpc/network.bsky.jetstream.planSnapshot, listSegments, getSegment, getBlock
    """)
  end

  def health(conn, _),
    do: respond(conn, %{"status" => "ok", "phase" => Aerox.Jetstream.Store.phase()})

  def not_implemented(_conn, _), do: {:error, Error.not_implemented()}
end
