defmodule Aerox.PDS.Repo.Migrations.CreateInteropProgress do
  @moduledoc """
  DESIGN §13.2: the bundle import's progress lives *in the target database*
  (the `did-map.json` incident — a progress file that survived a `destroy`
  silently skipped 2027 accounts). One row per DID: the current phase, when
  it finished, and the last error. A row is only trusted while the account
  it describes actually exists; the importer re-checks.
  """
  use Ecto.Migration

  def change do
    create table(:interop_progress, primary_key: false) do
      add :did, :text, primary_key: true
      add :phase, :text, null: false
      add :done_at, :utc_datetime_usec
      add :error, :text
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:interop_progress, [:phase])
  end
end
