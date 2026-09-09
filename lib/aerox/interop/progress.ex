defmodule Aerox.Interop.Progress do
  @moduledoc """
  The import's progress table, `interop_progress` in `aerox_pds`
  (DESIGN §13.2: progress lives in the target database, never in a file
  that survives a `destroy`). One row per DID with the current phase.

  A `done` row is only trusted while the account it describes exists:
  `done?/1` re-checks `actor` and `repo_root`, so a target that was wiped
  underneath a stale progress table is re-imported rather than skipped
  (the did-map regression, VERIFICATION §8).
  """
  use Ecto.Schema
  import Ecto.Query
  alias Aerox.PDS.Repo
  alias Aerox.PDS.Schema.{Actor, RepoRoot}

  @primary_key {:did, :string, autogenerate: false}
  schema "interop_progress" do
    field :phase, :string
    field :done_at, :utc_datetime_usec
    field :error, :string
    field :updated_at, :utc_datetime_usec
  end

  @phases ~w(verifying importing done failed)

  @doc "Upserts the phase for a DID (`done` sets `done_at`; `failed` records the error)."
  @spec set(String.t(), String.t(), String.t() | nil) :: :ok
  def set(did, phase, error \\ nil) when phase in @phases do
    now = DateTime.utc_now()

    Repo.insert_all(
      __MODULE__,
      [
        %{
          did: did,
          phase: phase,
          done_at: if(phase == "done", do: now),
          error: error && String.slice(error, 0, 4000),
          updated_at: now
        }
      ],
      on_conflict: {:replace, [:phase, :done_at, :error, :updated_at]},
      conflict_target: :did
    )

    :ok
  end

  @doc "The row for a DID, or nil."
  @spec get(String.t()) :: %__MODULE__{} | nil
  def get(did), do: Repo.get(__MODULE__, did)

  @doc "True only when progress says done *and* the account is actually present."
  @spec done?(String.t()) :: boolean
  def done?(did) do
    case get(did) do
      %{phase: "done"} -> present?(did)
      _ -> false
    end
  end

  @doc "Progress says done but the account is gone: the stale-progress signature."
  @spec stale?(String.t()) :: boolean
  def stale?(did) do
    match?(%{phase: "done"}, get(did)) and not present?(did)
  end

  defp present?(did) do
    Repo.exists?(from(a in Actor, where: a.did == ^did)) and
      Repo.exists?(from(r in RepoRoot, where: r.did == ^did))
  end

  @doc "Every row, for the run summary."
  @spec all() :: [%__MODULE__{}]
  def all, do: Repo.all(from(p in __MODULE__, order_by: p.did))
end
