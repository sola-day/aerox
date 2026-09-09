defmodule Aerox.PLC.AdminLog do
  @moduledoc "Append-only record of admin actions on the directory (`removeInvalidOps`)."
  use Ecto.Schema

  schema "admin_logs" do
    field :type, :string
    field :data, :map
    field :inserted_at, :utc_datetime_usec
  end
end
