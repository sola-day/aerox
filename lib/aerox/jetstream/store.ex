defmodule Aerox.Jetstream.Store do
  @moduledoc "Jetstream's small durable key-value state (`state` table): the relay cursor, the phase, the compaction watermark."
  alias Aerox.Jetstream.Repo
  alias Aerox.Jetstream.Schema.State

  def get(key, default \\ nil) do
    case Repo.get(State, key) do
      %State{value: %{"v" => v}} -> v
      _ -> default
    end
  end

  def put(key, value) do
    Repo.insert_all(State, [%{key: key, value: %{"v" => value}, updated_at: DateTime.utc_now()}],
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key
    )

    :ok
  end

  @doc "`bootstrap` until the initial backfill has merged, then `steady_state` (upstream `lifecycle`)."
  def phase, do: get("phase", "bootstrap")
  def steady_state?, do: phase() == "steady_state"
end
