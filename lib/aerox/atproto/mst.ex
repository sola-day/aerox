defmodule Aerox.ATProto.MST do
  @moduledoc """
  Merkle Search Tree (DESIGN §3.5) as pure functions over an explicit
  blockstore. Transcribed from `atproto/packages/repo/src/mst` (62f944dd);
  the structural verifier follows indigo `mst/verify.go`.

  Keys are `collection/rkey`; values are record CIDs. A key's layer is the
  number of leading zero bits of sha256(key) divided by two; tree shape
  depends on the key set only. Node encoding is `{l, e: [{p, k, v, t}]}`
  with `k` as **bytes**.

  A node is `%MST{}`: `entries` is `nil` until loaded from the blockstore
  (lazy, so a partial tree — the few dozen blocks a firehose commit carries
  — is a first-class value), and `cid` is `nil` while the node is dirty.
  Every operation returns the new tree; nothing is mutated. Missing blocks
  surface as `{:error, {:missing_block, cid}}` from the public functions.
  """
  alias Aerox.ATProto.{Blockstore, Bytes, CID, DagCBOR}

  defstruct entries: nil, cid: nil, layer: nil

  @type leaf :: {:leaf, String.t(), CID.t()}
  @type entry :: leaf | {:tree, t}
  @type t :: %__MODULE__{entries: [entry] | nil, cid: CID.t() | nil, layer: non_neg_integer | nil}

  @max_key_len 1024

  defmodule MissingBlock do
    defexception [:cid]
    def message(%{cid: cid}), do: "missing MST block #{cid}"
  end

  # ------------------------------------------------------------- basics

  @doc "A new, empty tree."
  @spec empty() :: t
  def empty, do: %__MODULE__{entries: [], cid: nil, layer: nil}

  @doc "A lazy handle on a stored tree."
  @spec load(CID.t()) :: t
  def load(%CID{} = cid), do: %__MODULE__{entries: nil, cid: cid, layer: nil}

  @doc "Number of leading zero *bit pairs* in sha256(key): the key's layer."
  @spec leading_zeros(String.t()) :: non_neg_integer
  def leading_zeros(key), do: key |> then(&:crypto.hash(:sha256, &1)) |> count_zeros(0)

  defp count_zeros(<<0, rest::binary>>, n), do: count_zeros(rest, n + 4)
  defp count_zeros(<<b, _::binary>>, n) when b < 4, do: n + 3
  defp count_zeros(<<b, _::binary>>, n) when b < 16, do: n + 2
  defp count_zeros(<<b, _::binary>>, n) when b < 64, do: n + 1
  defp count_zeros(_, n), do: n

  @doc "MST key rule: `collection/rkey`, ASCII `[a-zA-Z0-9_~:.-]`, both parts non-empty, ≤ 1024 bytes."
  @spec valid_key?(String.t()) :: boolean
  def valid_key?(key) when is_binary(key) do
    byte_size(key) <= @max_key_len and
      case String.split(key, "/") do
        [coll, rkey] when coll != "" and rkey != "" -> valid_chars?(coll) and valid_chars?(rkey)
        _ -> false
      end
  end

  def valid_key?(_), do: false

  defp valid_chars?(str), do: Regex.match?(~r/^[a-zA-Z0-9_\-:.~]*$/, str)

  defp ensure_valid_key!(key) do
    if valid_key?(key), do: :ok, else: raise(ArgumentError, "invalid MST key: #{inspect(key)}")
  end

  # ---------------------------------------------------------- run/catch

  # Public functions run the recursive core inside `run/1`, turning a
  # MissingBlock exception into an error tuple.
  defp run(fun) do
    {:ok, fun.()}
  rescue
    e in MissingBlock -> {:error, {:missing_block, e.cid}}
  end

  # --------------------------------------------------------------- load

  defp entries!(_bs, %__MODULE__{entries: entries} = node) when is_list(entries),
    do: {entries, node}

  defp entries!(bs, %__MODULE__{entries: nil, cid: cid} = node) do
    case Blockstore.get(bs, cid) do
      {:ok, bytes} ->
        data = DagCBOR.decode!(bytes)

        layer =
          with [%{"k" => %Bytes{data: k}, "p" => 0} | _] <- data["e"],
               do: leading_zeros(k),
               else: (_ -> nil)

        entries = deserialize(bs, data, layer)
        {entries, %{node | entries: entries, layer: node.layer || layer}}

      :error ->
        raise MissingBlock, cid: cid
    end
  end

  defp deserialize(_bs, %{"l" => left, "e" => e}, layer) do
    child_layer = if layer, do: layer - 1

    head =
      case left do
        %CID{} -> [{:tree, %__MODULE__{cid: left, layer: child_layer}}]
        nil -> []
      end

    {entries, _} =
      Enum.reduce(e, {head, ""}, fn %{
                                      "p" => p,
                                      "k" => %Bytes{data: k},
                                      "v" => %CID{} = v,
                                      "t" => t
                                    },
                                    {acc, last} ->
        key = binary_part(last, 0, p) <> k
        ensure_valid_key!(key)
        acc = [{:leaf, key, v} | acc]

        acc =
          if match?(%CID{}, t),
            do: [{:tree, %__MODULE__{cid: t, layer: child_layer}} | acc],
            else: acc

        {acc, key}
      end)

    Enum.reverse(entries)
  end

  @doc "The node's data-model form, `{l, e}`."
  @spec node_data([entry]) :: map
  def node_data(entries) do
    {left, rest} =
      case entries do
        [{:tree, sub} | rest] -> {sub.cid || raise("dirty subtree"), rest}
        rest -> {nil, rest}
      end

    {e, _} =
      rest
      |> chunk_entries([])
      |> Enum.map_reduce("", fn {key, value, sub}, last ->
        p = common_prefix(last, key)
        t = if sub, do: sub.cid || raise("dirty subtree"), else: nil

        {%{
           "p" => p,
           "k" => Bytes.new(binary_part(key, p, byte_size(key) - p)),
           "v" => value,
           "t" => t
         }, key}
      end)

    %{"l" => left, "e" => e}
  end

  defp chunk_entries([], acc), do: Enum.reverse(acc)

  defp chunk_entries([{:leaf, k, v}, {:tree, sub} | rest], acc),
    do: chunk_entries(rest, [{k, v, sub} | acc])

  defp chunk_entries([{:leaf, k, v} | rest], acc), do: chunk_entries(rest, [{k, v, nil} | acc])

  defp chunk_entries([{:tree, _} | _], _),
    do: raise(ArgumentError, "not a valid node: two subtrees next to each other")

  @doc "Length of the common prefix of two keys, in bytes."
  @spec common_prefix(binary, binary) :: non_neg_integer
  def common_prefix(a, b), do: common_prefix(a, b, 0)
  defp common_prefix(<<c, ra::binary>>, <<c, rb::binary>>, n), do: common_prefix(ra, rb, n + 1)
  defp common_prefix(_, _, n), do: n

  # ------------------------------------------------------------ pointer

  # Serialises a (possibly dirty) node, recursively fixing dirty subtrees.
  # Returns {cid, bytes, node} where node has every pointer filled in.
  defp serialize!(bs, node) do
    {entries, node} = entries!(bs, node)

    entries =
      Enum.map(entries, fn
        {:tree, %__MODULE__{cid: nil} = sub} ->
          {_, _, sub} = serialize!(bs, sub)
          {:tree, sub}

        other ->
          other
      end)

    bytes = entries |> node_data() |> DagCBOR.encode()
    cid = CID.for_cbor(bytes)
    {cid, bytes, %{node | entries: entries, cid: cid}}
  end

  defp pointer!(_bs, %__MODULE__{cid: %CID{} = cid} = node), do: {cid, node}

  defp pointer!(bs, node) do
    {cid, _bytes, node} = serialize!(bs, node)
    {cid, node}
  end

  @doc "The root CID (computing it if the tree is dirty); also returns the tree with pointers filled in."
  @spec root(Blockstore.t(), t) :: {:ok, CID.t(), t} | {:error, term}
  def root(bs, node) do
    case run(fn -> pointer!(bs, node) end) do
      {:ok, {cid, node}} -> {:ok, cid, node}
      error -> error
    end
  end

  # -------------------------------------------------------------- layer

  defp layer!(_bs, %__MODULE__{layer: l} = node) when is_integer(l), do: {l, node}

  defp layer!(bs, node) do
    case attempt_layer!(bs, node) do
      {nil, node} -> {0, %{node | layer: 0}}
      {l, node} -> {l, %{node | layer: l}}
    end
  end

  defp attempt_layer!(_bs, %__MODULE__{layer: l} = node) when is_integer(l), do: {l, node}

  defp attempt_layer!(bs, node) do
    {entries, node} = entries!(bs, node)

    case Enum.find(entries, &match?({:leaf, _, _}, &1)) do
      {:leaf, key, _} ->
        l = leading_zeros(key)
        {l, %{node | layer: l}}

      nil ->
        entries
        |> Enum.find_value(fn
          {:tree, sub} ->
            case attempt_layer!(bs, sub) do
              {nil, _} -> nil
              {l, _} -> l + 1
            end

          _ ->
            nil
        end)
        |> case do
          nil -> {nil, node}
          l -> {l, %{node | layer: l}}
        end
    end
  end

  # ---------------------------------------------------------------- get

  @doc "Looks a key up."
  @spec get(Blockstore.t(), t, String.t()) :: {:ok, CID.t() | nil} | {:error, term}
  def get(bs, node, key), do: run(fn -> get!(bs, node, key) end)

  defp get!(bs, node, key) do
    {entries, _node} = entries!(bs, node)
    index = gte_index(entries, key)

    case Enum.at(entries, index) do
      {:leaf, ^key, value} ->
        value

      _ ->
        case prev(entries, index) do
          {:tree, sub} -> get!(bs, sub, key)
          _ -> nil
        end
    end
  end

  defp gte_index(entries, key) do
    Enum.find_index(entries, fn
      {:leaf, k, _} -> k >= key
      _ -> false
    end) || length(entries)
  end

  defp prev(_entries, 0), do: nil
  defp prev(entries, index), do: Enum.at(entries, index - 1)

  # ---------------------------------------------------------------- add

  @doc "Inserts a key; errors if it exists."
  @spec add(Blockstore.t(), t, String.t(), CID.t()) :: {:ok, t} | {:error, term}
  def add(bs, node, key, value) do
    ensure_valid_key!(key)
    run(fn -> add!(bs, node, key, value, leading_zeros(key)) end)
  end

  defp add!(bs, node, key, value, key_zeros) do
    {layer, node} = layer!(bs, node)
    {entries, node} = entries!(bs, node)
    new_leaf = {:leaf, key, value}

    cond do
      key_zeros == layer ->
        index = gte_index(entries, key)

        case Enum.at(entries, index) do
          {:leaf, ^key, _} -> raise ArgumentError, "There is already a value at key: #{key}"
          _ -> :ok
        end

        case prev(entries, index) do
          {:tree, sub} ->
            {left, right} = split_around!(bs, sub, key)
            replace_with_split(node, index - 1, left, new_leaf, right)

          _ ->
            new_tree(node, List.insert_at(entries, index, new_leaf))
        end

      key_zeros < layer ->
        index = gte_index(entries, key)

        case prev(entries, index) do
          {:tree, sub} ->
            new_tree(
              node,
              List.replace_at(entries, index - 1, {:tree, add!(bs, sub, key, value, key_zeros)})
            )

          _ ->
            child = %__MODULE__{entries: [], layer: layer - 1}

            new_tree(
              node,
              List.insert_at(entries, index, {:tree, add!(bs, child, key, value, key_zeros)})
            )
        end

      true ->
        {left, right} = split_around!(bs, node, key)
        extra = key_zeros - layer

        {left, right} =
          Enum.reduce(1..(extra - 1)//1, {left, right}, fn _, {l, r} ->
            {l && create_parent(l), r && create_parent(r)}
          end)

        entries =
          Enum.reject([left && {:tree, left}, new_leaf, right && {:tree, right}], &is_nil/1)

        %__MODULE__{entries: entries, cid: nil, layer: key_zeros}
    end
  end

  defp new_tree(node, entries), do: %{node | entries: entries, cid: nil}

  defp create_parent(%__MODULE__{layer: layer} = sub),
    do: %__MODULE__{entries: [{:tree, sub}], cid: nil, layer: layer + 1}

  defp replace_with_split(node, index, left, leaf, right) do
    {entries, _} = {node.entries, node}
    {before, [_ | after_]} = Enum.split(entries, index)
    middle = Enum.reject([left && {:tree, left}, leaf, right && {:tree, right}], &is_nil/1)
    new_tree(node, before ++ middle ++ after_)
  end

  # Splits a subtree around a key, returning {left | nil, right | nil}.
  defp split_around!(bs, node, key) do
    {entries, node} = entries!(bs, node)
    index = gte_index(entries, key)
    {left_data, right_data} = Enum.split(entries, index)
    left = new_tree(node, left_data)
    right = new_tree(node, right_data)

    {left, right} =
      case List.last(left_data) do
        {:tree, last_sub} ->
          left = new_tree(left, Enum.drop(left_data, -1))
          {sl, sr} = split_around!(bs, last_sub, key)
          left = if sl, do: new_tree(left, left.entries ++ [{:tree, sl}]), else: left
          right = if sr, do: new_tree(right, [{:tree, sr} | right.entries]), else: right
          {left, right}

        _ ->
          {left, right}
      end

    {if(left.entries == [], do: nil, else: left), if(right.entries == [], do: nil, else: right)}
  end

  # ------------------------------------------------------------- update

  @doc "Replaces the value of an existing key."
  @spec update(Blockstore.t(), t, String.t(), CID.t()) :: {:ok, t} | {:error, term}
  def update(bs, node, key, value) do
    ensure_valid_key!(key)
    run(fn -> update!(bs, node, key, value) end)
  end

  defp update!(bs, node, key, value) do
    {entries, node} = entries!(bs, node)
    index = gte_index(entries, key)

    case Enum.at(entries, index) do
      {:leaf, ^key, _} ->
        new_tree(node, List.replace_at(entries, index, {:leaf, key, value}))

      _ ->
        case prev(entries, index) do
          {:tree, sub} ->
            new_tree(
              node,
              List.replace_at(entries, index - 1, {:tree, update!(bs, sub, key, value)})
            )

          _ ->
            raise ArgumentError, "Could not find a record with key: #{key}"
        end
    end
  end

  # ------------------------------------------------------------- delete

  @doc "Removes a key; errors if absent."
  @spec delete(Blockstore.t(), t, String.t()) :: {:ok, t} | {:error, term}
  def delete(bs, node, key), do: run(fn -> bs |> delete!(node, key) |> trim_top!(bs) end)

  defp delete!(bs, node, key) do
    {entries, node} = entries!(bs, node)
    index = gte_index(entries, key)

    case Enum.at(entries, index) do
      {:leaf, ^key, _} ->
        case {prev(entries, index), Enum.at(entries, index + 1)} do
          {{:tree, p}, {:tree, n}} ->
            merged = append_merge!(bs, p, n)
            {before, _} = Enum.split(entries, index - 1)
            new_tree(node, before ++ [{:tree, merged}] ++ Enum.drop(entries, index + 2))

          _ ->
            new_tree(node, List.delete_at(entries, index))
        end

      _ ->
        case prev(entries, index) do
          {:tree, sub} ->
            sub = delete!(bs, sub, key)

            if sub.entries == [],
              do: new_tree(node, List.delete_at(entries, index - 1)),
              else: new_tree(node, List.replace_at(entries, index - 1, {:tree, sub}))

          _ ->
            raise ArgumentError, "Could not find a record with key: #{key}"
        end
    end
  end

  defp trim_top!(node, bs) do
    entries =
      try do
        {entries, _} = entries!(bs, node)
        entries
      rescue
        MissingBlock -> :missing
      end

    case entries do
      [{:tree, sub}] -> trim_top!(sub, bs)
      _ -> node
    end
  end

  defp append_merge!(bs, left, right) do
    {ll, left} = layer!(bs, left)
    {rl, right} = layer!(bs, right)

    if ll != rl,
      do: raise(ArgumentError, "Trying to merge two nodes from different layers of the MST")

    {le, left} = entries!(bs, left)
    {re, _right} = entries!(bs, right)

    case {List.last(le), List.first(re)} do
      {{:tree, a}, {:tree, b}} ->
        new_tree(
          left,
          Enum.drop(le, -1) ++ [{:tree, append_merge!(bs, a, b)}] ++ Enum.drop(re, 1)
        )

      _ ->
        new_tree(left, le ++ re)
    end
  end

  # --------------------------------------------------------------- walk

  @doc "Every leaf in key order as `{key, cid}`."
  @spec leaves(Blockstore.t(), t) :: {:ok, [{String.t(), CID.t()}]} | {:error, term}
  def leaves(bs, node), do: run(fn -> bs |> walk!(node) |> Enum.reverse() end)

  defp walk!(bs, node, acc \\ []) do
    {entries, _} = entries!(bs, node)

    Enum.reduce(entries, acc, fn
      {:leaf, k, v}, acc -> [{k, v} | acc]
      {:tree, sub}, acc -> walk!(bs, sub, acc)
    end)
  end

  @doc "Leaves whose key starts with `prefix`, at most `count`."
  @spec list_with_prefix(Blockstore.t(), t, String.t(), non_neg_integer | :infinity) ::
          {:ok, [{String.t(), CID.t()}]} | {:error, term}
  def list_with_prefix(bs, node, prefix, count \\ :infinity) do
    run(fn ->
      bs
      |> walk_from!(node, prefix)
      |> Stream.take_while(fn {k, _} -> String.starts_with?(k, prefix) end)
      |> then(&if(count == :infinity, do: &1, else: Stream.take(&1, count)))
      |> Enum.to_list()
    end)
  end

  @doc "Leaves with key > `after_key` (or all, when nil), at most `count`, optionally before `before`."
  @spec list(Blockstore.t(), t, keyword) :: {:ok, [{String.t(), CID.t()}]} | {:error, term}
  def list(bs, node, opts \\ []) do
    after_key = Keyword.get(opts, :after, "")
    before = Keyword.get(opts, :before)
    count = Keyword.get(opts, :count, :infinity)

    run(fn ->
      bs
      |> walk_from!(node, after_key)
      |> Stream.reject(fn {k, _} -> k == after_key end)
      |> then(&if(before, do: Stream.take_while(&1, fn {k, _} -> k < before end), else: &1))
      |> then(&if(count == :infinity, do: &1, else: Stream.take(&1, count)))
      |> Enum.to_list()
    end)
  end

  # Lazily walks leaves with key >= from. Eager per node, lazy across nodes.
  defp walk_from!(bs, node, from) do
    Stream.resource(
      fn -> [{:node, node}] end,
      fn
        [] ->
          {:halt, []}

        [{:node, n} | stack] ->
          {entries, _} = entries!(bs, n)
          index = gte_index(entries, from)
          {before, rest} = Enum.split(entries, index)

          head =
            case List.last(before) do
              {:tree, sub} -> [{:node, sub}]
              _ -> []
            end

          {[],
           head ++
             Enum.map(rest, fn
               {:leaf, k, v} -> {:leaf, k, v}
               {:tree, s} -> {:node, s}
             end) ++ stack}

        [{:leaf, k, v} | stack] ->
          {[{k, v}], stack}
      end,
      fn _ -> :ok end
    )
  end

  @spec leaf_count(Blockstore.t(), t) :: {:ok, non_neg_integer} | {:error, term}
  def leaf_count(bs, node) do
    with {:ok, leaves} <- leaves(bs, node), do: {:ok, length(leaves)}
  end

  @doc "The layer of the root node (0 for an empty tree)."
  @spec layer(Blockstore.t(), t) :: {:ok, non_neg_integer} | {:error, term}
  def layer(bs, node) do
    case run(fn -> layer!(bs, node) end) do
      {:ok, {l, _}} -> {:ok, l}
      error -> error
    end
  end

  @doc """
  Loads the whole tree and recomputes every node CID from scratch, ignoring
  the CIDs the blocks were stored under — the DESIGN §3.5 step-1 proof that
  DAG-CBOR, CID and the MST agree with whoever wrote the blocks.
  """
  @spec recompute_root(Blockstore.t(), t) :: {:ok, CID.t()} | {:error, term}
  def recompute_root(bs, node) do
    run(fn ->
      {cid, _, _} = serialize!(bs, strip!(bs, node))
      cid
    end)
  end

  defp strip!(bs, node) do
    {entries, node} = entries!(bs, node)

    entries =
      Enum.map(entries, fn
        {:tree, sub} -> {:tree, strip!(bs, sub)}
        leaf -> leaf
      end)

    %{node | entries: entries, cid: nil}
  end

  # ------------------------------------------------------------- blocks

  @doc """
  Serialises every dirty node and returns `{root, blocks}` with the blocks
  the blockstore does not already hold, plus the tree with pointers set.
  """
  @spec unstored_blocks(Blockstore.t(), t) ::
          {:ok, CID.t(), [Blockstore.block()], t} | {:error, term}
  def unstored_blocks(bs, node) do
    case run(fn -> unstored!(bs, node) end) do
      {:ok, {cid, blocks, node}} -> {:ok, cid, Enum.reverse(blocks), node}
      error -> error
    end
  end

  defp unstored!(bs, node, acc \\ []) do
    {cid, bytes, node} = serialize!(bs, node)

    if Blockstore.has?(bs, cid) do
      {cid, acc, node}
    else
      acc = [{cid, bytes} | acc]

      acc =
        Enum.reduce(node.entries, acc, fn
          {:tree, sub}, acc ->
            {_, acc, _} = unstored!(bs, sub, acc)
            acc

          _, acc ->
            acc
        end)

      {cid, acc, node}
    end
  end

  @doc "Every node CID and leaf value CID reachable from the root, plus the root."
  @spec all_cids(Blockstore.t(), t) :: {:ok, MapSet.t(CID.t())} | {:error, term}
  def all_cids(bs, node), do: run(fn -> all_cids!(bs, node, MapSet.new()) end)

  defp all_cids!(bs, node, set) do
    {cid, node} = pointer!(bs, node)
    {entries, _} = entries!(bs, node)

    Enum.reduce(entries, MapSet.put(set, cid), fn
      {:leaf, _, v}, set -> MapSet.put(set, v)
      {:tree, sub}, set -> all_cids!(bs, sub, set)
    end)
  end

  @doc "Every MST node block reachable from the root, as `{cid, bytes}` (the CAR's MST section)."
  @spec node_blocks(Blockstore.t(), t) :: {:ok, [Blockstore.block()]} | {:error, term}
  def node_blocks(bs, node), do: run(fn -> bs |> node_blocks!(node, []) |> Enum.reverse() end)

  defp node_blocks!(bs, node, acc) do
    {cid, bytes, node} = serialize!(bs, node)

    Enum.reduce(node.entries, [{cid, bytes} | acc], fn
      {:tree, sub}, acc -> node_blocks!(bs, sub, acc)
      _, acc -> acc
    end)
  end

  # --------------------------------------------------------------- diff

  defmodule Diff do
    @moduledoc "The change set between two trees (upstream's DataDiff)."
    defstruct adds: %{},
              updates: %{},
              deletes: %{},
              new_mst_blocks: %{},
              new_leaf_cids: MapSet.new(),
              removed_cids: MapSet.new()

    @type t :: %__MODULE__{
            adds: %{String.t() => CID.t()},
            updates: %{String.t() => {CID.t(), CID.t()}},
            deletes: %{String.t() => CID.t()},
            new_mst_blocks: %{CID.t() => binary},
            new_leaf_cids: MapSet.t(CID.t()),
            removed_cids: MapSet.t(CID.t())
          }

    @doc "Keys touched, sorted."
    def updated_keys(%__MODULE__{} = d),
      do:
        (Map.keys(d.adds) ++ Map.keys(d.updates) ++ Map.keys(d.deletes))
        |> Enum.uniq()
        |> Enum.sort()
  end

  @doc """
  The diff from `prev` to `curr` (upstream's `mstDiff`): leaf adds, updates
  and deletes, the new MST node blocks, new leaf CIDs and removed CIDs.
  `prev` may be nil (everything is an add).
  """
  @spec diff(Blockstore.t(), t | nil, t) :: {:ok, Diff.t()} | {:error, term}
  def diff(bs, prev, curr), do: run(fn -> diff!(bs, prev, curr) end)

  defp diff!(bs, nil, curr) do
    {_, curr} = pointer!(bs, curr)
    null_diff!(bs, curr, %Diff{})
  end

  defp diff!(bs, prev, curr) do
    {_, curr} = pointer!(bs, curr)
    {_, prev} = pointer!(bs, prev)
    walk_diff(bs, walker_new(bs, prev), walker_new(bs, curr), %Diff{})
  end

  defp null_diff!(bs, node, diff) do
    diff = tree_add(diff, bs, node)
    {entries, _} = entries!(bs, node)

    Enum.reduce(entries, diff, fn
      {:leaf, k, v}, d -> leaf_add(d, k, v)
      {:tree, sub}, d -> null_diff!(bs, sub, d)
    end)
  end

  # The walker (upstream MstWalker): `curr` is the entry under the cursor,
  # `walking` the node whose entries are being traversed (nil while the
  # cursor is on the root itself), `stack` the suspended parent positions.
  defp walker_new(_bs, node),
    do: %{done: false, curr: {:tree, node}, walking: nil, index: 0, stack: []}

  defp w_curr(%{curr: curr}), do: curr
  defp w_done?(%{done: done}), do: done

  defp w_layer(bs, %{walking: %__MODULE__{} = walking}) do
    {l, _} = layer!(bs, walking)
    l
  end

  defp w_layer(bs, %{curr: {:tree, node}}) do
    {l, _} = layer!(bs, node)
    l + 1
  end

  # step_over: move to the next sibling, popping finished levels; the subtree
  # under the cursor (if any) is skipped entirely.
  defp w_step_over(_bs, %{done: true} = w), do: w
  defp w_step_over(_bs, %{walking: nil} = w), do: %{w | done: true}

  defp w_step_over(bs, %{walking: walking, index: index} = w) do
    {entries, _} = entries!(bs, walking)

    case Enum.at(entries, index + 1) do
      nil ->
        case w.stack do
          [] -> %{w | done: true}
          [popped | rest] -> w_step_over(bs, %{popped | stack: rest})
        end

      next ->
        %{w | curr: next, index: index + 1}
    end
  end

  # step_into: descend into the subtree under the cursor.
  defp w_step_into(_bs, %{done: true} = w), do: w

  defp w_step_into(bs, %{walking: nil, curr: {:tree, root}} = w) do
    {entries, root} = entries!(bs, root)

    case entries do
      [] -> %{w | done: true}
      [first | _] -> %{w | walking: root, curr: first, index: 0}
    end
  end

  defp w_step_into(bs, %{curr: {:tree, sub}} = w) do
    {entries, sub} = entries!(bs, sub)

    case entries do
      [] ->
        raise ArgumentError, "Tried to step into a node with 0 entries which is invalid"

      [first | _] ->
        %{w | walking: sub, curr: first, index: 0, stack: [%{w | stack: []} | w.stack]}
    end
  end

  # advance: a leaf is stepped over, a subtree is stepped into.
  defp w_advance(bs, %{curr: {:tree, _}} = w), do: w_step_into(bs, w)
  defp w_advance(bs, w), do: w_step_over(bs, w)

  defp walk_diff(bs, left, right, diff) do
    cond do
      w_done?(left) and w_done?(right) ->
        diff

      w_done?(left) ->
        walk_diff(bs, left, w_advance(bs, right), node_add(diff, bs, w_curr(right)))

      w_done?(right) ->
        walk_diff(bs, w_advance(bs, left), right, node_delete(diff, bs, w_curr(left)))

      true ->
        l = w_curr(left)
        r = w_curr(right)

        case {l, r} do
          {{:leaf, lk, lv}, {:leaf, rk, rv}} ->
            cond do
              lk == rk ->
                diff = if lv == rv, do: diff, else: leaf_update(diff, lk, lv, rv)
                walk_diff(bs, w_advance(bs, left), w_advance(bs, right), diff)

              lk < rk ->
                walk_diff(bs, w_advance(bs, left), right, leaf_delete(diff, lk, lv))

              true ->
                walk_diff(bs, left, w_advance(bs, right), leaf_add(diff, rk, rv))
            end

          _ ->
            cond do
              w_layer(bs, left) > w_layer(bs, right) ->
                case l do
                  {:leaf, _, _} ->
                    walk_diff(bs, left, w_advance(bs, right), node_add(diff, bs, r))

                  {:tree, _} ->
                    walk_diff(bs, w_step_into(bs, left), right, node_delete(diff, bs, l))
                end

              w_layer(bs, left) < w_layer(bs, right) ->
                case r do
                  {:leaf, _, _} ->
                    walk_diff(bs, w_advance(bs, left), right, node_delete(diff, bs, l))

                  {:tree, _} ->
                    walk_diff(bs, left, w_step_into(bs, right), node_add(diff, bs, r))
                end

              true ->
                case {l, r} do
                  {{:tree, ls}, {:tree, rs}} ->
                    {lc, _} = pointer!(bs, ls)
                    {rc, _} = pointer!(bs, rs)

                    if lc == rc do
                      walk_diff(bs, w_step_over(bs, left), w_step_over(bs, right), diff)
                    else
                      diff = diff |> node_add(bs, r) |> node_delete(bs, l)
                      walk_diff(bs, w_step_into(bs, left), w_step_into(bs, right), diff)
                    end

                  {{:leaf, _, _}, {:tree, _}} ->
                    walk_diff(bs, left, w_step_into(bs, right), node_add(diff, bs, r))

                  {{:tree, _}, {:leaf, _, _}} ->
                    walk_diff(bs, w_step_into(bs, left), right, node_delete(diff, bs, l))
                end
            end
        end
    end
  end

  defp node_add(diff, _bs, {:leaf, k, v}), do: leaf_add(diff, k, v)
  defp node_add(diff, bs, {:tree, sub}), do: tree_add(diff, bs, sub)

  defp node_delete(diff, _bs, {:leaf, k, v}),
    do: %{
      diff
      | deletes: Map.put(diff.deletes, k, v),
        removed_cids: MapSet.put(diff.removed_cids, v)
    }

  defp node_delete(diff, bs, {:tree, sub}) do
    {cid, _} = pointer!(bs, sub)
    tree_delete(diff, cid)
  end

  defp leaf_add(diff, k, v) do
    diff = %{diff | adds: Map.put(diff.adds, k, v)}

    if MapSet.member?(diff.removed_cids, v),
      do: %{diff | removed_cids: MapSet.delete(diff.removed_cids, v)},
      else: %{diff | new_leaf_cids: MapSet.put(diff.new_leaf_cids, v)}
  end

  defp leaf_update(diff, k, prev, v) do
    %{
      diff
      | updates: Map.put(diff.updates, k, {prev, v}),
        removed_cids: MapSet.put(diff.removed_cids, prev),
        new_leaf_cids: MapSet.put(diff.new_leaf_cids, v)
    }
  end

  defp leaf_delete(diff, k, v) do
    diff = %{diff | deletes: Map.put(diff.deletes, k, v)}

    if MapSet.member?(diff.new_leaf_cids, v),
      do: %{diff | new_leaf_cids: MapSet.delete(diff.new_leaf_cids, v)},
      else: %{diff | removed_cids: MapSet.put(diff.removed_cids, v)}
  end

  defp tree_add(diff, bs, node) do
    {cid, bytes, _} = serialize!(bs, node)

    if MapSet.member?(diff.removed_cids, cid),
      do: %{diff | removed_cids: MapSet.delete(diff.removed_cids, cid)},
      else: %{diff | new_mst_blocks: Map.put(diff.new_mst_blocks, cid, bytes)}
  end

  defp tree_delete(diff, cid) do
    if Map.has_key?(diff.new_mst_blocks, cid),
      do: %{diff | new_mst_blocks: Map.delete(diff.new_mst_blocks, cid)},
      else: %{diff | removed_cids: MapSet.put(diff.removed_cids, cid)}
  end

  # ------------------------------------------------------------- proofs

  @doc """
  The covering proof for a key (upstream `getCoveringProof`): the node blocks
  on the path to the key plus those on the paths to its left and right
  neighbours. With only these blocks a partial tree can invert the mutation
  at `key` and recompute the previous root — the inductive check the Relay
  runs on every commit (DESIGN §3.6).
  """
  @spec covering_proof(Blockstore.t(), t, String.t()) ::
          {:ok, %{CID.t() => binary}} | {:error, term}
  def covering_proof(bs, node, key) do
    run(fn ->
      {_, node} = pointer!(bs, node)

      %{}
      |> proof_for_key!(bs, node, key)
      |> proof_for_left_sib!(bs, node, key)
      |> proof_for_right_sib!(bs, node, key)
    end)
  end

  defp add_self(acc, bs, node) do
    {cid, bytes, _} = serialize!(bs, node)
    Map.put(acc, cid, bytes)
  end

  defp proof_for_key!(acc, bs, node, key) do
    {entries, node} = entries!(bs, node)
    index = gte_index(entries, key)

    case Enum.at(entries, index) do
      {:leaf, ^key, _} ->
        add_self(acc, bs, node)

      _ ->
        case prev(entries, index) do
          {:tree, sub} -> acc |> proof_for_key!(bs, sub, key) |> add_self(bs, node)
          _ -> acc
        end
    end
  end

  defp proof_for_left_sib!(acc, bs, node, key) do
    {entries, node} = entries!(bs, node)
    index = gte_index(entries, key)

    acc =
      case prev(entries, index) do
        {:tree, sub} -> proof_for_left_sib!(acc, bs, sub, key)
        _ -> acc
      end

    add_self(acc, bs, node)
  end

  defp proof_for_right_sib!(acc, bs, node, key) do
    {entries, node} = entries!(bs, node)
    index = gte_index(entries, key)
    found = Enum.at(entries, index) || prev(entries, index)

    acc =
      case found do
        nil ->
          acc

        {:tree, sub} ->
          proof_for_right_sib!(acc, bs, sub, key)

        {:leaf, k, _} ->
          neighbour = if k == key, do: Enum.at(entries, index + 1), else: prev(entries, index)

          case neighbour do
            {:tree, sub} -> proof_for_right_sib!(acc, bs, sub, key)
            _ -> acc
          end
      end

    add_self(acc, bs, node)
  end

  @doc "The node CIDs on the path to a key plus the leaf's value CID (upstream `cidsForPath`), for `getRecord` proofs."
  @spec cids_for_path(Blockstore.t(), t, String.t()) :: {:ok, [CID.t()]} | {:error, term}
  def cids_for_path(bs, node, key), do: run(fn -> cids_for_path!(bs, node, key) end)

  defp cids_for_path!(bs, node, key) do
    {cid, node} = pointer!(bs, node)
    {entries, _} = entries!(bs, node)
    index = gte_index(entries, key)

    case Enum.at(entries, index) do
      {:leaf, ^key, value} ->
        [cid, value]

      _ ->
        case prev(entries, index) do
          {:tree, sub} -> [cid | cids_for_path!(bs, sub, key)]
          _ -> [cid]
        end
    end
  end

  # ------------------------------------------------------------- verify

  @doc """
  Structural verification (indigo `mst/verify.go`): every node's layer is
  right for its keys, keys are strictly increasing, no two subtrees are
  adjacent, no subtree below layer 0, no empty non-root node. Subtrees whose
  blocks are absent are not descended into (a partial tree can still be
  checked as far as it goes).
  """
  @spec verify_structure(Blockstore.t(), t) :: :ok | {:error, term}
  def verify_structure(bs, node) do
    case run(fn -> verify!(bs, node, nil, nil) end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, _} = e} -> e
      error -> error
    end
  end

  defp verify!(bs, node, height, last_key) do
    entries =
      try do
        {entries, _} = entries!(bs, node)
        entries
      rescue
        MissingBlock -> :missing
      end

    case entries do
      :missing ->
        {:ok, last_key}

      [] when is_integer(height) ->
        {:error, :empty_tree_node}

      [] ->
        :ok

      entries ->
        height =
          height ||
            Enum.find_value(entries, fn
              {:leaf, k, _} -> leading_zeros(k)
              _ -> nil
            end)

        if height == nil do
          {:error, :top_of_tree_is_just_a_pointer}
        else
          verify_entries(bs, entries, height, last_key, false)
        end
    end
    |> case do
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp verify_entries(_bs, [], _height, last_key, _last_child), do: {:ok, last_key}

  defp verify_entries(bs, [{:tree, sub} | rest], height, last_key, last_child) do
    cond do
      last_child ->
        {:error, :sibling_children}

      height == 0 ->
        {:error, :child_below_zero}

      true ->
        case verify!(bs, sub, height - 1, last_key) do
          :ok -> verify_entries(bs, rest, height, last_key, true)
          {:ok, last_key} -> verify_entries(bs, rest, height, last_key, true)
          error -> error
        end
    end
  end

  defp verify_entries(bs, [{:leaf, key, _} | rest], height, last_key, _last_child) do
    cond do
      last_key != nil and key == last_key -> {:error, :duplicate_key}
      last_key != nil and key < last_key -> {:error, :out_of_order_keys}
      leading_zeros(key) != height -> {:error, {:wrong_height_for_key, key}}
      true -> verify_entries(bs, rest, height, key, false)
    end
  end
end
