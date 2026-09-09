defmodule Aerox.AppView.Repo.Migrations.AddOban do
  @moduledoc "The core-side Oban instance lives in the appview schema (DESIGN §21.6)."
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14, prefix: "appview")
  def down, do: Oban.Migration.down(version: 1, prefix: "appview")
end
