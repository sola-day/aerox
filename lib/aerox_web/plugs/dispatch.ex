defmodule AeroxWeb.Dispatch do
  @moduledoc """
  Routes a request to the router of the service its `Host` names: the Relay's
  hostname goes to `AeroxWeb.RelayRouter`, the AppView's to
  `AeroxWeb.AppViewRouter` (M7), everything else to `AeroxWeb.Router` (the PDS,
  the PLC and the handle catch-all). Every service in the all-in-one dev stack
  shares one endpoint behind Traefik, so the hostname is the only discriminator.
  """
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    router =
      cond do
        conn.host == Aerox.Relay.Config.hostname() ->
          AeroxWeb.RelayRouter

        conn.host == Aerox.AppView.Config.hostname() ->
          AeroxWeb.AppViewRouter

        conn.host == Aerox.Jetstream.Config.hostname() ->
          AeroxWeb.JetstreamRouter

        conn.host == Aerox.Labeler.Config.hostname() and
            Code.ensure_loaded?(AeroxWeb.LabelerRouter) ->
          AeroxWeb.LabelerRouter

        true ->
          AeroxWeb.Router
      end

    router.call(conn, router.init([]))
  end
end
