defmodule Aerox.PDS.Repo do
  @moduledoc """
  The PDS's own database, `aerox_pds` (DESIGN §4.6). User-owned, per-instance
  data: accounts, sessions, repos, blobs metadata, the sequencer log. Connects
  as the `aerox_pds` role; nothing else may connect to this database.
  """
  use Ecto.Repo, otp_app: :aerox, adapter: Ecto.Adapters.Postgres
end
