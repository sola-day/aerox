# The Labeler's Ecto schemas, one per table of the `labeler` migration
# (DESIGN §17). Plain row shapes with no behaviour, kept together.

defmodule Aerox.Labeler.Schema.Label do
  @moduledoc "A signed label (`com.atproto.label.defs#label` plus `seq`), upstream ozone's `label` row."
  use Ecto.Schema

  schema "label" do
    field :src, :string
    field :uri, :string
    field :cid, :string, default: ""
    field :val, :string
    field :neg, :boolean, default: false
    field :cts, :utc_datetime_usec
    field :exp, :utc_datetime_usec
    field :sig, :binary
    field :ver, :integer, default: 1
    field :seq, :integer
  end
end

defmodule Aerox.Labeler.Schema.LabelSeq do
  @moduledoc "The `subscribeLabels` sequencer table (DESIGN §5 shape)."
  use Ecto.Schema

  @primary_key {:seq, :integer, autogenerate: false}
  schema "label_seq" do
    field :did, :string
    field :event_type, :string
    field :event, :binary
    field :invalidated, :boolean, default: false
    field :sequenced_at, :utc_datetime_usec
  end
end

defmodule Aerox.Labeler.Schema.ModReport do
  @moduledoc "A `com.atproto.moderation.createReport` intake row (DESIGN §17.2)."
  use Ecto.Schema

  schema "mod_report" do
    field :subject, :map
    field :reason_type, :string
    field :reason, :string
    field :reported_by, :string
    field :created_at, :utc_datetime_usec
  end
end

defmodule Aerox.Labeler.Schema.ModEvent do
  @moduledoc "The append-only moderation event log (DESIGN §17.2)."
  use Ecto.Schema

  schema "mod_event" do
    field :action, :string
    field :subject, :map
    field :created_by, :string
    field :comment, :string
    field :meta, :map, default: %{}
    field :created_at, :utc_datetime_usec
    field :applied_at, :utc_datetime_usec
  end
end

defmodule Aerox.Labeler.Schema.Setting do
  @moduledoc "Key/value settings the setup task persists (the labeler DID and signing key)."
  use Ecto.Schema

  @primary_key {:key, :string, autogenerate: false}
  schema "setting" do
    field :value, :string
    field :updated_at, :utc_datetime_usec
  end
end
