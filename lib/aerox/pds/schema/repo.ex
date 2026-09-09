defmodule Aerox.PDS.Schema.RepoRoot do
  @moduledoc "Current commit per account; its row is the per-account write lock (DESIGN §21.3)."
  use Ecto.Schema

  @primary_key {:did, :string, autogenerate: false}
  schema "repo_root" do
    field :cid, :string
    field :rev, :string
    field :indexed_at, :utc_datetime_usec
  end
end

defmodule Aerox.PDS.Schema.RepoBlock do
  @moduledoc "Raw DAG-CBOR bytes: the Postgres Blockstore (DESIGN §4.2)."
  use Ecto.Schema

  @primary_key false
  schema "repo_block" do
    field :did, :string, primary_key: true
    field :cid, :string, primary_key: true
    field :rev, :string
    field :size, :integer
    field :content, :binary
  end
end

defmodule Aerox.PDS.Schema.Record do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "record" do
    field :did, :string, primary_key: true
    field :collection, :string, primary_key: true
    field :rkey, :string, primary_key: true
    field :uri, :string
    field :cid, :string
    field :rev, :string
    field :indexed_at, :utc_datetime_usec
    field :takedown_ref, :string
  end
end

defmodule Aerox.PDS.Schema.Backlink do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "backlink" do
    field :did, :string, primary_key: true
    field :uri, :string, primary_key: true
    field :path, :string, primary_key: true
    field :link_to, :string
  end
end

defmodule Aerox.PDS.Schema.Blob do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "blob" do
    field :did, :string, primary_key: true
    field :cid, :string, primary_key: true
    field :mime_type, :string
    field :size, :integer
    field :temp_key, :string
    field :created_at, :utc_datetime_usec
    field :takedown_ref, :string
  end
end

defmodule Aerox.PDS.Schema.RecordBlob do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "record_blob" do
    field :did, :string, primary_key: true
    field :blob_cid, :string, primary_key: true
    field :record_uri, :string, primary_key: true
  end
end

defmodule Aerox.PDS.Schema.AccountPref do
  @moduledoc false
  use Ecto.Schema

  schema "account_pref" do
    field :did, :string
    field :name, :string
    field :value, :map
  end
end

defmodule Aerox.PDS.Schema.RepoSeq do
  @moduledoc "The sequencer's event log (DESIGN §4.7)."
  use Ecto.Schema

  @primary_key {:seq, :integer, autogenerate: false}
  schema "repo_seq" do
    field :did, :string
    field :event_type, :string
    field :event, :binary
    field :invalidated, :boolean, default: false
    field :sequenced_at, :utc_datetime_usec
  end
end

defmodule Aerox.PDS.Schema.PlcOpAudit do
  @moduledoc "Every PLC operation this PDS signs (DESIGN §14.2 point 5)."
  use Ecto.Schema

  schema "plc_op_audit" do
    field :did, :string
    field :cid, :string
    field :purpose, :string
    field :actor, :string
    field :inserted_at, :utc_datetime_usec
  end
end
