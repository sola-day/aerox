# Jetstream's Ecto schemas, one per table of the `jetstream` migration: plain row shapes.

defmodule Aerox.Jetstream.Schema.EventRow do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:seq, :integer, autogenerate: false}
  schema "event" do
    field :witnessed_at, :integer
    field :indexed_at, :integer, default: 0
    field :kind, :integer
    field :did, :string
    field :collection, :string, default: ""
    field :rkey, :string, default: ""
    field :rev, :string, default: ""
    field :payload, :binary
  end
end

defmodule Aerox.Jetstream.Schema.BootstrapLive do
  @moduledoc false
  use Ecto.Schema

  schema "bootstrap_live" do
    field :kind, :integer
    field :did, :string
    field :collection, :string, default: ""
    field :rkey, :string, default: ""
    field :rev, :string, default: ""
    field :payload, :binary
  end
end

defmodule Aerox.Jetstream.Schema.State do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:key, :string, autogenerate: false}
  schema "state" do
    field :value, :map
    field :updated_at, :utc_datetime_usec
  end
end

defmodule Aerox.Jetstream.Schema.RepoRow do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:did, :string, autogenerate: false}
  schema "repo" do
    field :status, :string
    field :pds, :string
    field :backfill_rev, :string
    field :attempts, :integer, default: 0
    field :next_attempt_at, :utc_datetime_usec
    field :error, :string
    field :updated_at, :utc_datetime_usec
  end
end

defmodule Aerox.Jetstream.Schema.Tombstone do
  @moduledoc false
  use Ecto.Schema

  schema "tombstone" do
    field :seq, :integer
    field :scope, :string
    field :key, :string
  end
end

defmodule Aerox.Jetstream.Schema.TimestampRule do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "timestamp_rule" do
    field :uri, :string, primary_key: true
    field :cid, :string, primary_key: true
    field :indexed_at, :integer
  end
end

defmodule Aerox.Jetstream.Schema.ImportJob do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "import_job" do
    field :path, :string
    field :state, :string
    field :phase, :string
    field :error, :string
    field :counters, :map, default: %{}
    field :submitted_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
  end
end
