defmodule Aerox.Relay.Schema.Host do
  @moduledoc "An upstream PDS host the Relay consumes (indigo `models.Host`)."
  use Ecto.Schema

  schema "host" do
    field :hostname, :string
    field :no_ssl, :boolean, default: false
    field :account_limit, :integer, default: 100
    field :trusted, :boolean, default: false
    field :status, :string, default: "active"
    field :last_seq, :integer, default: -1
    field :account_count, :integer, default: 0
    field :error_count, :integer, default: 0
    field :last_event_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Aerox.Relay.Schema.Account do
  @moduledoc "An account (repo) seen on a host (indigo `models.Account`)."
  use Ecto.Schema

  @primary_key {:uid, :id, autogenerate: true}
  schema "account" do
    field :did, :string
    field :host_id, :integer
    field :status, :string, default: "active"
    field :upstream_status, :string, default: "active"
    field :collections_crawled_at, :utc_datetime_usec
  end

  @doc "Active when both the local and the upstream status are active."
  def active?(%__MODULE__{status: "active", upstream_status: "active"}), do: true
  def active?(_), do: false

  @doc "The status reported to consumers: local takedown/throttle wins over upstream."
  def status_field(%__MODULE__{status: "active", upstream_status: "active"}), do: nil
  def status_field(%__MODULE__{status: "active", upstream_status: s}), do: s
  def status_field(%__MODULE__{status: s}), do: s
end

defmodule Aerox.Relay.Schema.AccountRepo do
  @moduledoc "The latest verified commit of an account (indigo `models.AccountRepo`)."
  use Ecto.Schema

  @primary_key {:uid, :integer, autogenerate: false}
  schema "account_repo" do
    field :rev, :string
    field :commit_cid, :string
    field :commit_data_cid, :string
  end
end

defmodule Aerox.Relay.Schema.RepoSeq do
  @moduledoc "The Relay's re-sequenced firehose (DESIGN §19)."
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

defmodule Aerox.Relay.Schema.DomainBan do
  @moduledoc "A banned host domain (indigo `models.DomainBan`)."
  use Ecto.Schema

  @primary_key {:domain, :string, autogenerate: false}
  schema "domain_ban" do
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Aerox.Relay.Schema.RepoCollection do
  @moduledoc "A DID with records in a collection (indigo `collectiondir`)."
  use Ecto.Schema

  schema "repo_collection" do
    field :collection, :string
    field :did, :string
    field :inserted_at, :utc_datetime_usec
  end
end
