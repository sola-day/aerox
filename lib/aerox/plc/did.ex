defmodule Aerox.PLC.Did do
  @moduledoc "A row of `plc.dids`: exists once a DID has any operation; locked `FOR UPDATE` while one is added."
  use Ecto.Schema

  @primary_key false
  schema "dids" do
    field :did, :string, primary_key: true
    field :inserted_at, :utc_datetime_usec
  end
end
