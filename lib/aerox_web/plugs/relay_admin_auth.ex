defmodule AeroxWeb.Relay.AdminAuth do
  @moduledoc "HTTP Basic `admin:<relay admin password>` → `assigns.relay_admin?` (indigo's admin routes)."
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    admin? =
      with ["Basic " <> creds] <- get_req_header(conn, "authorization"),
           {:ok, decoded} <- Base.decode64(creds),
           ["admin", password] <- String.split(decoded, ":", parts: 2),
           expected when is_binary(expected) <- Aerox.Relay.Config.admin_password() do
        Plug.Crypto.secure_compare(password, expected)
      else
        _ -> false
      end

    assign(conn, :relay_admin?, admin?)
  end
end
