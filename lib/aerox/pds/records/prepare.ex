defmodule Aerox.PDS.Records.Prepare do
  @moduledoc """
  Upstream `repo/prepare.ts`: turns an API write into a prepared write —
  `$type` filled in or checked against the collection, record key validated
  (or minted from the clock), the record's DAG-CBOR CID computed, blob refs
  enumerated (legacy blobs refused), and the three-state lexicon validation
  of DESIGN §6.3 applied.
  """
  alias Aerox.ATProto.{CID, Data, DagCBOR, Lexicon, Syntax}
  alias Aerox.PDS.Handle.Slurs

  @max_record_bytes 1_000_000

  @type prepared ::
          %{
            action: :create | :update,
            collection: String.t(),
            rkey: String.t(),
            uri: String.t(),
            cid: CID.t(),
            record: map,
            blobs: [map],
            validation_status: :valid | :unknown | :skipped,
            swap_cid: CID.t() | nil | :unset
          }
          | %{
              action: :delete,
              collection: String.t(),
              rkey: String.t(),
              uri: String.t(),
              swap_cid: CID.t() | nil | :unset
            }

  @type error ::
          {:error,
           {:invalid_record, String.t()}
           | {:invalid_record_key, String.t()}
           | {:unknown_lexicon, String.t()}}

  @doc """
  Options: `rkey:` (default: a new TID), `validate:` (nil/true/false),
  `swap_cid:`, `registry:` (default vendored), `next_tid:` (a 0-arity function).
  """
  @spec create(String.t(), String.t(), term, keyword) :: {:ok, prepared} | error
  def create(did, collection, record, opts \\ []),
    do: prepare(:create, did, collection, record, opts)

  @spec update(String.t(), String.t(), String.t(), term, keyword) :: {:ok, prepared} | error
  def update(did, collection, rkey, record, opts \\ []),
    do: prepare(:update, did, collection, record, Keyword.put(opts, :rkey, rkey))

  @spec delete(String.t(), String.t(), String.t(), keyword) :: {:ok, prepared}
  def delete(did, collection, rkey, opts \\ []) do
    {:ok,
     %{
       action: :delete,
       collection: collection,
       rkey: rkey,
       uri: Syntax.at_uri(did, collection, rkey),
       swap_cid: Keyword.get(opts, :swap_cid, :unset)
     }}
  end

  defp prepare(action, did, collection, record, opts) do
    with :ok <-
           if(Syntax.valid_nsid?(collection),
             do: :ok,
             else: {:error, {:invalid_record, "Invalid collection: #{collection}"}}
           ),
         {:ok, record} <- typed(record, collection),
         {:ok, record} <- to_model(record),
         {:ok, rkey} <- rkey(opts),
         {:ok, status} <- validation(record, rkey, collection, opts),
         {:ok, blobs} <- blob_refs(record),
         bytes = DagCBOR.encode(record),
         :ok <-
           if(byte_size(bytes) <= @max_record_bytes,
             do: :ok,
             else: {:error, {:invalid_record, "Record is too large"}}
           ) do
      {:ok,
       %{
         action: action,
         collection: collection,
         rkey: rkey,
         uri: Syntax.at_uri(did, collection, rkey),
         cid: CID.for_cbor(bytes),
         record: record,
         blobs: blobs,
         validation_status: status,
         swap_cid: Keyword.get(opts, :swap_cid, :unset)
       }}
    end
  end

  defp typed(%{} = record, collection) do
    case Map.get(record, "$type") do
      nil ->
        {:ok, Map.put(record, "$type", collection)}

      ^collection ->
        {:ok, record}

      other ->
        {:error,
         {:invalid_record, "Invalid $type: expected #{collection}, got #{inspect(other)}"}}
    end
  end

  defp typed(_, _), do: {:error, {:invalid_record, "Record must be an object"}}

  # Records arrive as JSON: convert $link/$bytes and validate the data model.
  defp to_model(record) do
    case Data.from_json(record) do
      {:ok, value} ->
        {:ok, value}

      {:error, {msg, path}} ->
        {:error, {:invalid_record, "Invalid record at /#{Enum.join(path, "/")}: #{msg}"}}
    end
  end

  defp rkey(opts) do
    case Keyword.get(opts, :rkey) do
      nil ->
        {:ok, Keyword.get(opts, :next_tid, fn -> Aerox.PDS.Clock.next_tid() end).()}

      rkey ->
        cond do
          not Syntax.valid_record_key?(rkey) ->
            {:error, {:invalid_record_key, "Invalid record key: #{rkey}"}}

          Slurs.explicit_slur?(rkey) ->
            {:error, {:invalid_record, "Unacceptable slur in record key"}}

          true ->
            {:ok, rkey}
        end
    end
  end

  defp validation(record, rkey, collection, opts) do
    registry = Keyword.get(opts, :registry) || Lexicon.default_registry()
    validate = Keyword.get(opts, :validate)

    case Lexicon.record_status(registry, record, validate) do
      {:ok, :valid} ->
        if Lexicon.valid_record_key?(registry, collection, rkey),
          do: {:ok, :valid},
          else: {:error, {:invalid_record, "Invalid record key for #{collection}: #{rkey}"}}

      {:ok, status} ->
        {:ok, status}

      {:error, {:unknown_lexicon, type}} ->
        {:error, {:invalid_record, "Unknown lexicon type: #{type}"}}

      {:error, {:invalid_record, msg, path}} ->
        {:error,
         {:invalid_record, "Invalid #{collection} record: #{msg} (at #{Enum.join(path, "/")})"}}

      {:error, other} ->
        {:error, {:invalid_record, inspect(other)}}
    end
  end

  # Legacy blob refs {cid, mimeType} are normalised by the Data layer to
  # size -1; upstream refuses them on write.
  defp blob_refs(record) do
    blobs = Data.blob_refs(record)

    case Enum.find(blobs, &(&1["size"] == -1)) do
      nil -> {:ok, blobs}
      blob -> {:error, {:invalid_record, "Legacy blobs are not allowed (#{blob["ref"]})"}}
    end
  end
end
