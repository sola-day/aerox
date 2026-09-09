defmodule Aerox.PDS.Schema.Device do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "device" do
    field :session_id, :string
    field :user_agent, :string
    field :ip_address, :string
    field :last_seen_at, :utc_datetime_usec
  end
end

defmodule Aerox.PDS.Schema.AccountDevice do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "account_device" do
    field :did, :string, primary_key: true
    field :device_id, :string, primary_key: true
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end

defmodule Aerox.PDS.Schema.AuthorizationRequest do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "authorization_request" do
    field :did, :string
    field :device_id, :string
    field :client_id, :string
    field :client_auth, :map
    field :parameters, :map
    field :expires_at, :utc_datetime_usec
    field :code, :string
  end
end

defmodule Aerox.PDS.Schema.OAuthToken do
  @moduledoc false
  use Ecto.Schema

  schema "oauth_token" do
    field :did, :string
    field :token_id, :string
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :client_id, :string
    field :client_auth, :map
    field :device_id, :string
    field :parameters, :map
    field :details, :map
    field :code, :string
    field :current_refresh_token, :string
    field :scope, :string
  end
end

defmodule Aerox.PDS.Schema.UsedRefreshToken do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:refresh_token, :string, autogenerate: false}
  schema "used_refresh_token" do
    field :token_id, :integer
  end
end

defmodule Aerox.PDS.Schema.AuthorizedClient do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "authorized_client" do
    field :did, :string, primary_key: true
    field :client_id, :string, primary_key: true
    field :created_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
    field :data, :map
  end
end
