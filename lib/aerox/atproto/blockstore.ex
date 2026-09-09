defmodule Aerox.ATProto.Blockstore do
  @moduledoc """
  Content-addressed block storage as a behaviour with explicit state
  (DESIGN §3.5). Every MST and CAR function takes a blockstore
  `{module, state}` explicitly — no process, no `Process.put` — so the same
  code runs over Postgres in the PDS, over a CAR on import, over the few
  dozen blocks a firehose commit carries in the Relay, and over a map in
  tests. Implementations outside the kernel (Postgres) carry their own
  state; `Memory` and `Layered` live here.
  """
  alias Aerox.ATProto.CID

  @type state :: term
  @type t :: {module, state}
  @type block :: {CID.t(), binary}

  @callback get(state, CID.t()) :: {:ok, binary} | :error
  @callback get_many(state, [CID.t()]) :: %{CID.t() => binary}
  @callback has?(state, CID.t()) :: boolean
  @callback put_many(state, [block]) :: {:ok, state}

  @spec get(t, CID.t()) :: {:ok, binary} | :error
  def get({mod, state}, cid), do: mod.get(state, cid)

  @spec get_many(t, [CID.t()]) :: %{CID.t() => binary}
  def get_many({mod, state}, cids), do: mod.get_many(state, cids)

  @spec has?(t, CID.t()) :: boolean
  def has?({mod, state}, cid), do: mod.has?(state, cid)

  @spec put_many(t, [block]) :: {:ok, t}
  def put_many({mod, state}, blocks) do
    {:ok, state} = mod.put_many(state, blocks)
    {:ok, {mod, state}}
  end

  @spec put(t, CID.t(), binary) :: {:ok, t}
  def put(bs, cid, bytes), do: put_many(bs, [{cid, bytes}])

  @doc "Stores a data-model value as a DAG-CBOR block; returns its CID."
  @spec put_value(t, Aerox.ATProto.DagCBOR.value()) :: {:ok, CID.t(), t}
  def put_value(bs, value) do
    bytes = Aerox.ATProto.DagCBOR.encode(value)
    cid = CID.for_cbor(bytes)
    {:ok, bs} = put(bs, cid, bytes)
    {:ok, cid, bs}
  end

  @doc "Reads and strictly decodes a DAG-CBOR block, checking the CID."
  @spec get_value(t, CID.t()) :: {:ok, Aerox.ATProto.DagCBOR.value()} | {:error, term}
  def get_value(bs, cid) do
    case get(bs, cid) do
      {:ok, bytes} ->
        if CID.verify(cid, bytes),
          do: Aerox.ATProto.DagCBOR.decode(bytes),
          else: {:error, {:cid_mismatch, cid}}

      :error ->
        {:error, {:missing_block, cid}}
    end
  end

  defmodule Memory do
    @moduledoc "A map from CID to bytes; the blockstore for tests, the Relay and CAR imports."
    @behaviour Aerox.ATProto.Blockstore

    @spec new([Aerox.ATProto.Blockstore.block()] | %{CID.t() => binary}) ::
            Aerox.ATProto.Blockstore.t()
    def new(blocks \\ %{})
    def new(%{} = map), do: {__MODULE__, map}
    def new(list) when is_list(list), do: {__MODULE__, Map.new(list)}

    @impl true
    def get(map, cid), do: Map.fetch(map, cid)

    @impl true
    def get_many(map, cids), do: Map.take(map, cids)

    @impl true
    def has?(map, cid), do: Map.has_key?(map, cid)

    @impl true
    def put_many(map, blocks), do: {:ok, Enum.into(blocks, map)}

    @doc "All blocks, for turning a memory store back into a CAR."
    @spec blocks(Aerox.ATProto.Blockstore.t()) :: %{CID.t() => binary}
    def blocks({__MODULE__, map}), do: map
  end

  defmodule Layered do
    @moduledoc """
    Reads from a staging store first, then a base store; writes go to the
    staging store. Verification of a commit stages the commit's blocks over
    the repo's existing storage without touching it (upstream's SyncStorage).
    """
    @behaviour Aerox.ATProto.Blockstore
    alias Aerox.ATProto.Blockstore

    @spec new(Blockstore.t(), Blockstore.t()) :: Blockstore.t()
    def new(staged, base), do: {__MODULE__, {staged, base}}

    @impl true
    def get({staged, base}, cid) do
      case Blockstore.get(staged, cid) do
        {:ok, _} = hit -> hit
        :error -> Blockstore.get(base, cid)
      end
    end

    @impl true
    def get_many({staged, base}, cids) do
      found = Blockstore.get_many(staged, cids)
      missing = Enum.reject(cids, &Map.has_key?(found, &1))
      if missing == [], do: found, else: Map.merge(Blockstore.get_many(base, missing), found)
    end

    @impl true
    def has?({staged, base}, cid), do: Blockstore.has?(staged, cid) or Blockstore.has?(base, cid)

    @impl true
    def put_many({staged, base}, blocks) do
      {:ok, staged} = Blockstore.put_many(staged, blocks)
      {:ok, {staged, base}}
    end
  end
end
