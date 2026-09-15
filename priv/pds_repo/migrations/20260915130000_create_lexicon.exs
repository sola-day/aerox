defmodule Aerox.PDS.Repo.Migrations.CreateLexicon do
  @moduledoc """
  Resolved lexicons (upstream oauth-provider `LexiconStore`, PDS migration
  006): what `Aerox.PDS.Lexicons` last resolved for an NSID, when it last
  tried and when it last succeeded, so a failed refresh can serve the last
  good document and a known-missing lexicon is not re-fetched on every
  request.
  """
  use Ecto.Migration

  def change do
    create table(:lexicon, primary_key: false) do
      add :nsid, :text, primary_key: true
      add :uri, :text
      add :cid, :text
      add :record, :map
      add :last_succeeded_at, :utc_datetime_usec
      add :updated_at, :utc_datetime_usec, null: false
      add :created_at, :utc_datetime_usec, null: false
    end
  end
end
