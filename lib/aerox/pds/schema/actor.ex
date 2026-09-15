defmodule Aerox.PDS.Schema.Actor do
  @moduledoc "Upstream `actor` plus the per-account signing key (DESIGN §4.5)."
  use Ecto.Schema

  @primary_key {:did, :string, autogenerate: false}
  schema "actor" do
    field :handle, :string
    field :signing_key, :binary, redact: true
    field :created_at, :utc_datetime_usec
    field :takedown_ref, :string
    field :deactivated_at, :utc_datetime_usec
    field :delete_after, :utc_datetime_usec
    has_one :account, Aerox.PDS.Schema.Account, foreign_key: :did, references: :did
  end
end

defmodule Aerox.PDS.Schema.Account do
  @moduledoc "Upstream `account`: email, scrypt password, confirmation."
  use Ecto.Schema

  @primary_key {:did, :string, autogenerate: false}
  schema "account" do
    field :email, :string
    field :password_scrypt, :string, redact: true
    field :email_confirmed_at, :utc_datetime_usec
    field :invites_disabled, :boolean, default: false
  end
end

defmodule Aerox.PDS.Schema.RefreshToken do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "refresh_token" do
    field :did, :string
    field :expires_at, :utc_datetime_usec
    field :app_password_name, :string
    field :next_id, :string
  end
end

defmodule Aerox.PDS.Schema.AppPassword do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "app_password" do
    field :did, :string, primary_key: true
    field :name, :string, primary_key: true
    field :password_scrypt, :string, redact: true
    field :created_at, :utc_datetime_usec
    field :privileged, :boolean, default: false
  end
end

defmodule Aerox.PDS.Schema.InviteCode do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:code, :string, autogenerate: false}
  schema "invite_code" do
    field :available_uses, :integer
    field :disabled, :boolean, default: false
    field :for_account, :string
    field :created_by, :string
    field :created_at, :utc_datetime_usec
  end
end

defmodule Aerox.PDS.Schema.InviteCodeUse do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "invite_code_use" do
    field :code, :string, primary_key: true
    field :used_by, :string, primary_key: true
    field :used_at, :utc_datetime_usec
  end
end

defmodule Aerox.PDS.Schema.EmailToken do
  @moduledoc "One outstanding token per `(did, purpose)` (DESIGN §18.1)."
  use Ecto.Schema

  @primary_key false
  schema "email_token" do
    field :purpose, :string, primary_key: true
    field :did, :string, primary_key: true
    field :token, :string
    field :requested_at, :utc_datetime_usec
  end
end

defmodule Aerox.PDS.Schema.ReservedSigningKey do
  @moduledoc "A signing key reserved ahead of account creation (upstream `reserveKeypair`)."
  use Ecto.Schema

  @primary_key {:key_did, :string, autogenerate: false}
  schema "reserved_signing_key" do
    field :did, :string
    field :private_key, :binary
    field :created_at, :utc_datetime_usec
  end
end
