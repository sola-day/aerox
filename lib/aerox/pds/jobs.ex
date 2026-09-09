defmodule Aerox.PDS.Jobs do
  @moduledoc """
  The PDS's Oban maintenance workers, on `Aerox.PDS.Oban` queue `:maintenance`
  (DESIGN §21.7). Scheduled by `Oban.Plugins.Cron` in `config :aerox, Oban.PDS`:

  * `ReapBlobs` — hourly; deletes blob bytes no row references (DESIGN §18.5).
  * `ReapSignups` — every 10 minutes; deletes accounts whose signup saga never
    published to PLC (DESIGN §18.3, `Aerox.PDS.Signup.reap_orphans/0`).
  * `RevokeExpiredTokens` — daily; prunes expired refresh tokens and email tokens.
  """

  defmodule ReapBlobs do
    @moduledoc false
    use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 3600]
    import Ecto.Query
    alias Aerox.PDS.{Blobs, Repo}
    alias Aerox.PDS.Schema.Actor

    @impl true
    def perform(%Oban.Job{args: %{"did" => did}}) do
      _ = Blobs.reap(did)
      :ok
    end

    def perform(%Oban.Job{}) do
      # fan out per account so one bad store never blocks the others
      jobs = from(a in Actor, select: a.did) |> Repo.all() |> Enum.map(&new(%{"did" => &1}))
      if jobs != [], do: Oban.insert_all(Aerox.PDS.Oban, jobs)
      :ok
    end
  end

  defmodule ReapSignups do
    @moduledoc false
    use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 300]

    @impl true
    def perform(_job) do
      _ = Aerox.PDS.Signup.reap_orphans()
      :ok
    end
  end

  defmodule RevokeExpiredTokens do
    @moduledoc false
    use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 3600]
    import Ecto.Query
    alias Aerox.PDS.Repo
    alias Aerox.PDS.Schema.{EmailToken, RefreshToken}

    @impl true
    def perform(_job) do
      now = DateTime.utc_now()
      Repo.delete_all(from(t in RefreshToken, where: t.expires_at < ^now))
      # email tokens outlive their validity window only to give a precise "expired" error
      day_ago = DateTime.add(now, -86_400, :second)
      Repo.delete_all(from(t in EmailToken, where: t.requested_at < ^day_ago))
      :ok
    end
  end
end
