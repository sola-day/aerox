defmodule Aerox.PLC.Operation do
  @moduledoc "A row of `plc.operations`."
  use Ecto.Schema
  alias Aerox.ATProto.CID

  @primary_key false
  schema "operations" do
    field :did, :string, primary_key: true
    field :cid, :string, primary_key: true
    field :operation, :map
    field :nullified, :boolean, default: false
    field :created_at, :utc_datetime_usec
    field :seq, :integer
  end

  @doc "The row in `Aerox.PLC.Operations`'s indexed shape."
  def to_indexed(%__MODULE__{} = row) do
    %{
      did: row.did,
      operation: row.operation,
      cid: CID.parse!(row.cid),
      nullified: row.nullified,
      created_at: row.created_at
    }
  end

  @doc "The row as `/log/audit` and `/export` present it."
  def to_exported(%__MODULE__{} = row, opts \\ []) do
    base = %{
      "did" => row.did,
      "operation" => row.operation,
      "cid" => row.cid,
      "createdAt" => Aerox.ATProto.Syntax.format_datetime(row.created_at)
    }

    if opts[:seq],
      do: base |> Map.put("seq", row.seq) |> Map.put("type", "sequenced_op"),
      else: Map.put(base, "nullified", row.nullified)
  end
end
