defmodule AeroxWeb.PDS.PreferencesController do
  @moduledoc "`app.bsky.actor.getPreferences` / `putPreferences`: served by the PDS because preferences live here (DESIGN §11.1)."
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  alias Aerox.PDS.{Accounts, Sessions}
  alias AeroxWeb.XRPC.Error

  def get_preferences(conn, _) do
    auth = require_auth!(conn, scopes: Sessions.access_standard() ++ [:takendown])
    full = auth.scope in Sessions.access_full()
    respond(conn, %{"preferences" => Accounts.get_preferences(auth.did, "app.bsky", full)})
  end

  def put_preferences(conn, _) do
    auth = require_auth!(conn)
    full = auth.scope in Sessions.access_full()

    prefs =
      conn.body_params["preferences"] || raise(Error.invalid_request("preferences required"))

    case Accounts.put_preferences(auth.did, prefs, "app.bsky", full) do
      :ok -> send_resp(conn, 200, "")
      {:error, msg} -> {:error, Error.invalid_request(msg)}
    end
  end
end
