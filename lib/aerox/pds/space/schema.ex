defmodule Aerox.PDS.Space.Schema do
  @moduledoc """
  Ecto schemas for the Spaces tables (DESIGN §12.3, migration
  `create_space_tables`). Every table is keyed by `did` — the account whose
  view of the space the row is — mirroring the upstream per-actor SQLite
  schemas inside one shared Postgres (DESIGN §4.2).
  """

  defmodule Space do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "space" do
      field :did, :string, primary_key: true
      field :uri, :string, primary_key: true
      field :is_owner, :boolean, default: false
      field :is_member, :boolean, default: false
      field :mint_policy, :string, default: "member-list"
      field :managing_app, :string
      field :is_public, :boolean, default: false
      field :app_access_mode, :string, default: "open"
      field :app_exceptions, {:array, :string}, default: []
      field :created_at, :utc_datetime_usec
      field :deleted_at, :utc_datetime_usec
    end
  end

  defmodule SpaceRepo do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "space_repo" do
      field :did, :string, primary_key: true
      field :space, :string, primary_key: true
      field :set_hash, :binary
      field :rev, :string
    end
  end

  defmodule SpaceRecord do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "space_record" do
      field :did, :string, primary_key: true
      field :space, :string, primary_key: true
      field :collection, :string, primary_key: true
      field :rkey, :string, primary_key: true
      field :cid, :string
      field :value, :binary
      field :repo_rev, :string
      field :indexed_at, :utc_datetime_usec
    end
  end

  defmodule SpaceRecordOplog do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "space_record_oplog" do
      field :did, :string, primary_key: true
      field :space, :string, primary_key: true
      field :rev, :string, primary_key: true
      field :idx, :integer, primary_key: true
      field :action, :string
      field :collection, :string
      field :rkey, :string
      field :cid, :string
      field :prev, :string
    end
  end

  defmodule SpaceMember do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "space_member" do
      field :did, :string, primary_key: true
      field :space, :string, primary_key: true
      field :member_did, :string, primary_key: true
      field :member_rev, :string, default: ""
    end
  end

  defmodule SpaceMemberState do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "space_member_state" do
      field :did, :string, primary_key: true
      field :space, :string, primary_key: true
      field :set_hash, :binary
      field :rev, :string
    end
  end

  defmodule SpaceMemberOplog do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "space_member_oplog" do
      field :did, :string, primary_key: true
      field :space, :string, primary_key: true
      field :rev, :string, primary_key: true
      field :idx, :integer, primary_key: true
      field :action, :string
      field :member_did, :string
    end
  end

  defmodule SpaceCredentialRecipient do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "space_credential_recipient" do
      field :did, :string, primary_key: true
      field :space, :string, primary_key: true
      field :service_did, :string, primary_key: true
      field :service_endpoint, :string
      field :last_issued_at, :utc_datetime_usec
    end
  end

  defmodule SpaceNotifyRegistration do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "space_notify_registration" do
      field :did, :string, primary_key: true
      field :space, :string, primary_key: true
      field :service, :string, primary_key: true
      field :endpoint, :string
      field :expires_at, :utc_datetime_usec
      field :created_at, :utc_datetime_usec
    end
  end

  defmodule SpaceWriter do
    @moduledoc false
    use Ecto.Schema

    @primary_key false
    schema "space_writer" do
      field :did, :string, primary_key: true
      field :space, :string, primary_key: true
      field :writer_did, :string, primary_key: true
      field :rev, :string
      field :hash, :binary
      field :updated_at, :utc_datetime_usec
    end
  end
end
