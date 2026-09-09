defmodule Aerox.PDS.Clock do
  @moduledoc """
  The stateful half of DESIGN §3.7: hands out strictly increasing TIDs for
  this node. The kernel's `TID.next/3` is pure; this process remembers the
  previous TID and owns the node's clock id. One per node (`:global`
  uniqueness is the R3 question, not this one).
  """
  use GenServer
  alias Aerox.ATProto.TID

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "The next TID, strictly newer than every TID this clock has issued."
  @spec next_tid(GenServer.server()) :: TID.t()
  def next_tid(server \\ __MODULE__), do: GenServer.call(server, :next)

  @doc "A TID strictly newer than `prev` (a repo's current rev) and than anything issued so far."
  @spec next_tid_after(String.t() | nil, GenServer.server()) :: TID.t()
  def next_tid_after(prev, server \\ __MODULE__), do: GenServer.call(server, {:next_after, prev})

  @impl true
  def init(opts) do
    {:ok, %{prev: nil, clock_id: Keyword.get(opts, :clock_id, :rand.uniform(32) - 1)}}
  end

  @impl true
  def handle_call(:next, _from, state) do
    tid = TID.next(state.prev, System.os_time(:microsecond), state.clock_id)
    {:reply, tid, %{state | prev: tid}}
  end

  def handle_call({:next_after, prev}, _from, state) do
    floor = Enum.max(Enum.reject([state.prev, prev], &is_nil/1), fn -> nil end)
    tid = TID.next(floor, System.os_time(:microsecond), state.clock_id)
    {:reply, tid, %{state | prev: tid}}
  end
end
