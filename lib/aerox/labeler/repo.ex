defmodule Aerox.Labeler.Repo do
  @moduledoc "Schema `labeler` in `aerox_core` (DESIGN §4.6, §17), connecting as the `aerox_labeler` role."
  use Ecto.Repo, otp_app: :aerox, adapter: Ecto.Adapters.Postgres
end
