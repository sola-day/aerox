defmodule AeroxWeb.AppView.NotificationController do
  @moduledoc "`app.bsky.notification.*` on the AppView host (DESIGN §15.5; upstream `api/app/bsky/notification/*`)."
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  import AeroxWeb.AppView.Helpers
  alias Aerox.AppView.Notifications
  alias AeroxWeb.XRPC.Error

  def list_notifications(conn, _) do
    p = params!(conn, "app.bsky.notification.listNotifications")
    _ = viewer!(conn)
    if p["seenAt"], do: raise(Error.invalid_request("The seenAt parameter is unsupported"))
    state = state(conn)

    body =
      Notifications.list(p["limit"] || 50, p["cursor"], p["reasons"], state)
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    respond_labeled(conn, state, body)
  end

  def get_unread_count(conn, _) do
    p = params!(conn, "app.bsky.notification.getUnreadCount")
    viewer = viewer!(conn)
    if p["seenAt"], do: raise(Error.invalid_request("The seenAt parameter is unsupported"))
    respond(conn, %{"count" => Notifications.unread_count(viewer)})
  end

  def update_seen(conn, _) do
    viewer = viewer!(conn)
    %{"seenAt" => seen_at} = input!(conn, "app.bsky.notification.updateSeen")

    case Aerox.ATProto.Syntax.parse_datetime(seen_at) do
      {:ok, dt} ->
        :ok = Notifications.update_seen(viewer, dt)
        send_resp(conn, 200, "")

      _ ->
        raise Error.invalid_request("Invalid seenAt")
    end
  end
end
