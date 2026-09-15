defmodule Aerox.Jetstream.Repo do
  @moduledoc "Schema `jetstream` in `aerox_core`, connecting as the `aerox_jetstream` role (DESIGN §4.6)."
  use Ecto.Repo, otp_app: :aerox, adapter: Ecto.Adapters.Postgres
end
