defmodule Aerox.PDS.Repo.Migrations.CreateSchema do
  @moduledoc """
  First migration of `aerox_pds` (DESIGN §4.6). The PDS owns the whole
  database, so its tables live in `public`; the migration only makes sure no
  other role can reach that schema through the default PUBLIC grant.
  """
  use Ecto.Migration

  def up do
    execute("REVOKE ALL ON SCHEMA public FROM PUBLIC")
    execute("GRANT ALL ON SCHEMA public TO aerox_pds")
  end

  def down do
    :ok
  end
end
