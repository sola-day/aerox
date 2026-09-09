defmodule Aerox.AppView.Repo do
  @moduledoc """
  Schema `appview` in `aerox_core` (DESIGN §4.6). Connects as the
  `aerox_appview` role, which owns that schema and has no privilege on `plc`
  or `relay`. Also hosts the core-side Oban instance (DESIGN §21.6).
  """
  use Ecto.Repo, otp_app: :aerox, adapter: Ecto.Adapters.Postgres
end
