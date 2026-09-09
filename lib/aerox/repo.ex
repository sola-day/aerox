defmodule Aerox.Repo do
  use Ecto.Repo,
    otp_app: :aerox,
    adapter: Ecto.Adapters.Postgres
end
