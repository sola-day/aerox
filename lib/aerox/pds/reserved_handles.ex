defmodule Aerox.PDS.ReservedHandles do
  @moduledoc """
  Whole handles an operator has reserved (`com.atproto.temp.addReservedHandle`),
  on top of the reserved first labels shipped in `priv/reserved_handles.txt`
  (`Aerox.PDS.Handle`). A reserved handle is refused at signup and handle
  change except by an admin.
  """
  import Ecto.Query
  alias Aerox.PDS.Repo
  alias Aerox.PDS.Schema.ReservedHandle

  @spec add(String.t()) :: :ok
  def add(handle) do
    Repo.insert_all(
      ReservedHandle,
      [%{handle: String.downcase(handle), created_at: DateTime.utc_now()}],
      on_conflict: :nothing
    )

    :ok
  end

  @spec reserved?(String.t()) :: boolean
  def reserved?(handle),
    do: Repo.exists?(from(r in ReservedHandle, where: r.handle == ^String.downcase(handle)))
end
