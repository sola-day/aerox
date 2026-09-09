defmodule Aerox.PLC.Repo do
  @moduledoc """
  Schema `plc` in `aerox_core` (DESIGN §4.6). Connects as the `aerox_plc` role,
  which owns that schema and has no privilege on `relay` or `appview`.
  """
  use Ecto.Repo, otp_app: :aerox, adapter: Ecto.Adapters.Postgres
end
