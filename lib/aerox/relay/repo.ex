defmodule Aerox.Relay.Repo do
  @moduledoc """
  Schema `relay` in `aerox_core` (DESIGN §4.6). Connects as the `aerox_relay`
  role, which owns that schema and has no privilege on `plc` or `appview`.
  """
  use Ecto.Repo, otp_app: :aerox, adapter: Ecto.Adapters.Postgres
end
