defmodule Aerox.PDS.Blockstore do
  @moduledoc """
  The Postgres implementation of the kernel's Blockstore over `repo_block`
  (DESIGN §4.2, §4.3), scoped to one DID. `put_many/2` is one multi-row
  insert with `ON CONFLICT DO NOTHING` — blocks are content-addressed and
  immutable. The `rev` recorded on inserted rows comes from the state.

  Runs inside whatever transaction the caller holds (the write path's
  `repo_root … FOR UPDATE`), through `Aerox.PDS.Repo`.
  """
  @behaviour Aerox.ATProto.Blockstore
  import Ecto.Query
  alias Aerox.ATProto.CID
  alias Aerox.PDS.Repo
  alias Aerox.PDS.Schema.RepoBlock

  @type state :: %{did: String.t(), rev: String.t() | nil}

  @spec new(String.t(), String.t() | nil) :: Aerox.ATProto.Blockstore.t()
  def new(did, rev \\ nil), do: {__MODULE__, %{did: did, rev: rev}}

  @impl true
  def get(%{did: did}, %CID{} = cid) do
    case Repo.one(
           from(b in RepoBlock,
             where: b.did == ^did and b.cid == ^CID.to_string(cid),
             select: b.content
           )
         ) do
      nil -> :error
      content -> {:ok, content}
    end
  end

  @impl true
  def get_many(%{did: did}, cids) do
    strs = Enum.map(cids, &CID.to_string/1)

    from(b in RepoBlock, where: b.did == ^did and b.cid in ^strs, select: {b.cid, b.content})
    |> Repo.all()
    |> Map.new(fn {cid, content} -> {CID.parse!(cid), content} end)
  end

  @impl true
  def has?(%{did: did}, %CID{} = cid) do
    Repo.exists?(from(b in RepoBlock, where: b.did == ^did and b.cid == ^CID.to_string(cid)))
  end

  @impl true
  def put_many(%{did: did, rev: rev} = state, blocks) do
    rows =
      Enum.map(blocks, fn {cid, bytes} ->
        %{
          did: did,
          cid: CID.to_string(cid),
          rev: rev || "",
          size: byte_size(bytes),
          content: bytes
        }
      end)

    rows
    |> Enum.chunk_every(100)
    |> Enum.each(
      &Repo.insert_all(RepoBlock, &1, on_conflict: :nothing, conflict_target: [:did, :cid])
    )

    {:ok, state}
  end

  @doc "Deletes blocks no longer referenced after a commit."
  @spec delete_many(String.t(), [CID.t()]) :: :ok
  def delete_many(_did, []), do: :ok

  def delete_many(did, cids) do
    strs = Enum.map(cids, &CID.to_string/1)
    Repo.delete_all(from(b in RepoBlock, where: b.did == ^did and b.cid in ^strs))
    :ok
  end

  @spec count(String.t()) :: non_neg_integer
  def count(did), do: Repo.aggregate(from(b in RepoBlock, where: b.did == ^did), :count)

  @doc "All block CIDs for a DID, for the reaper and import verification."
  @spec all_cids(String.t()) :: [CID.t()]
  def all_cids(did) do
    from(b in RepoBlock, where: b.did == ^did, select: b.cid, order_by: b.cid)
    |> Repo.all()
    |> Enum.map(&CID.parse!/1)
  end
end
