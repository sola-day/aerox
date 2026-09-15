defmodule Aerox.Jetstream.Convert do
  @moduledoc """
  Relay firehose events into Jetstream rows, through upstream's validation
  gate (docs/README.md §4.4):

  * a `#commit` or `#sync` whose `rev` is not a TID is dropped whole;
  * an op whose collection is not an NSID or whose rkey is not a record key is
    dropped alone, as is one whose record block is missing from the diff or
    whose fields exceed the block columns;
  * `#identity`, `#account` and `#sync` rows carry the upstream event as
    DAG-CBOR, a create/update its record's bytes exactly as the repo holds
    them, a delete nothing.

  Returns the rows (without seqs) and the drops, each with its reason.
  """
  alias Aerox.ATProto.{Bytes, CAR, CID, DagCBOR, Syntax}
  alias Aerox.Jetstream.{Block, Event}

  @type drop :: {atom, map}

  @spec rows(String.t(), map) :: {[Event.t()], [drop]}
  def rows("#commit", %{"repo" => did, "rev" => rev, "ops" => ops} = body) when is_list(ops) do
    cond do
      not Syntax.valid_tid?(rev) ->
        {[], [{:invalid_rev, %{did: did, rev: rev}}]}

      true ->
        blocks = diff_blocks(body["blocks"])

        Enum.reduce(ops, {[], []}, fn op, {rows, drops} ->
          case op_row(did, rev, op, blocks) do
            {:ok, row} -> {[row | rows], drops}
            {:drop, reason} -> {rows, [{reason, %{did: did, path: op["path"]}} | drops]}
          end
        end)
        |> then(fn {rows, drops} -> {Enum.reverse(rows), Enum.reverse(drops)} end)
    end
  end

  def rows("#identity", %{"did" => did} = body), do: marker(:identity, did, body)
  def rows("#account", %{"did" => did} = body), do: marker(:account, did, body)

  def rows("#sync", %{"did" => did, "rev" => rev} = body) do
    if Syntax.valid_tid?(rev),
      do: marker(:sync, did, body, rev),
      else: {[], [{:invalid_rev, %{did: did, rev: rev}}]}
  end

  def rows(_type, _body), do: {[], []}

  defp marker(kind, did, body, rev \\ "") do
    row = %Event{kind: kind, did: did, rev: rev, payload: DagCBOR.encode(body)}

    case Block.validate(row) do
      :ok -> {[row], []}
      {:error, _} -> {[], [{:field_too_long, %{did: did}}]}
    end
  end

  defp diff_blocks(%Bytes{data: car}) do
    case CAR.decode(car) do
      {:ok, %{blocks: blocks}} -> Map.new(blocks)
      _ -> %{}
    end
  end

  defp diff_blocks(_), do: %{}

  defp op_row(did, rev, %{"action" => action, "path" => path} = op, blocks)
       when is_binary(path) do
    with [collection, rkey] <- String.split(path, "/", parts: 2) |> pad(),
         true <- Syntax.valid_nsid?(collection) || :invalid_collection,
         true <- Syntax.valid_record_key?(rkey) || :invalid_rkey,
         {:ok, kind, payload} <- payload(action, op["cid"], blocks),
         row = %Event{
           kind: kind,
           did: did,
           collection: collection,
           rkey: rkey,
           rev: rev,
           payload: payload
         },
         :ok <- Block.validate(row) do
      {:ok, row}
    else
      reason when is_atom(reason) -> {:drop, reason}
      {:error, {:field_too_long, _}} -> {:drop, :field_too_long}
      {:error, reason} when is_atom(reason) -> {:drop, reason}
      _ -> {:drop, :invalid_op}
    end
  end

  defp op_row(_did, _rev, _op, _blocks), do: {:drop, :invalid_op}

  defp pad([c, r]), do: [c, r]
  defp pad(_), do: :invalid_collection

  defp payload("delete", _cid, _blocks), do: {:ok, :delete, ""}

  defp payload(action, %CID{} = cid, blocks) when action in ["create", "update"] do
    case Map.fetch(blocks, cid) do
      {:ok, bytes} -> {:ok, String.to_existing_atom(action), bytes}
      :error -> {:error, :missing_block}
    end
  end

  defp payload(_, _, _), do: {:error, :invalid_op}

  @doc "The replacement rows for a repo re-synchronised from its CAR: one `create_resync` per record (or `create` during bootstrap)."
  def repo_rows(did, rev, records, blockstore, kind \\ :create_resync) do
    Enum.flat_map(records, fn %{path: path, cid: cid} ->
      with [collection, rkey] <- String.split(path, "/", parts: 2),
           true <- Syntax.valid_nsid?(collection) and Syntax.valid_record_key?(rkey),
           {:ok, bytes} <- Aerox.ATProto.Blockstore.get(blockstore, cid),
           row = %Event{
             kind: kind,
             did: did,
             collection: collection,
             rkey: rkey,
             rev: rev,
             payload: bytes
           },
           :ok <- Block.validate(row) do
        [row]
      else
        _ -> []
      end
    end)
  end

  @doc "The DAG-CBOR bytes' CID, as rendered on the wire."
  def cid(payload), do: CID.to_string(CID.for_cbor(payload))
end
