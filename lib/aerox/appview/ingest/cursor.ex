defmodule Aerox.AppView.Ingest.Cursor do
  @moduledoc "The persisted firehose cursor, `appview.subscription` (DESIGN §15.1)."
  import Ecto.Query
  alias Aerox.AppView.Repo
  alias Aerox.AppView.Schema.Subscription

  @method "com.atproto.sync.subscribeRepos"

  def get(service) do
    case Repo.one(
           from(s in Subscription,
             where: s.service == ^service and s.method == ^@method,
             select: s.state
           )
         ) do
      %{"cursor" => cursor} when is_integer(cursor) -> cursor
      _ -> 0
    end
  end

  def put(service, cursor) do
    Repo.insert_all(
      Subscription,
      [
        %{
          service: service,
          method: @method,
          state: %{"cursor" => cursor},
          updated_at: DateTime.utc_now()
        }
      ],
      on_conflict: {:replace, [:state, :updated_at]},
      conflict_target: [:service, :method]
    )

    :ok
  end

  def reset(service), do: put(service, 0)
end
