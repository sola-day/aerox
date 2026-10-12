defmodule Aerox.PDS.Blobs do
  @moduledoc """
  Blob lifecycle on the PDS (DESIGN §4.4): upload streams to the adapter's
  temp area while hashing and sniffing, the `blob` row is written with
  `temp_key`, and a record write that references the blob makes it
  permanent (`Aerox.PDS.Records` inserts the `record_blob` rows; this
  module verifies and promotes). Postgres is the only source of truth for
  what exists; the reaper reconciles the adapter against it.
  """
  import Ecto.Query
  alias Aerox.ATProto.CID
  alias Aerox.Blob.{Mime, Store}
  alias Aerox.PDS.Repo
  alias Aerox.PDS.Schema.{Blob, Record, RecordBlob}

  @type metadata :: %{
          temp_key: String.t(),
          size: non_neg_integer,
          cid: CID.t(),
          mime_type: String.t()
        }

  @doc "Streams `chunks` to temp storage, computing size, sha-256 and the sniffed MIME in one pass."
  @spec upload(String.t(), String.t(), Enumerable.t()) :: {:ok, metadata} | {:error, term}
  def upload(did, suggested_mime, chunks) do
    hasher = :crypto.hash_init(:sha256)

    {chunks, %{hash: hash, size: size, head: head}} =
      Enum.map_reduce(chunks, %{hash: hasher, size: 0, head: <<>>}, fn chunk, acc ->
        head = if byte_size(acc.head) < 4100, do: acc.head <> chunk, else: acc.head

        {chunk,
         %{
           acc
           | hash: :crypto.hash_update(acc.hash, chunk),
             size: acc.size + byte_size(chunk),
             head: head
         }}
      end)

    with {:ok, temp_key} <- Store.put_temp(did, chunks) do
      digest = :crypto.hash_final(hash)
      cid = %CID{codec: :raw, digest: digest}

      mime =
        case Mime.sniff(head) do
          {:ok, m} -> m
          :unknown -> suggested_mime || "application/octet-stream"
        end

      {:ok, %{temp_key: temp_key, size: size, cid: cid, mime_type: mime}}
    end
  end

  @doc "Upstream `trackUntetheredBlob`: the blob row with its temp key; refuses taken-down blobs."
  @spec track(String.t(), metadata) :: {:ok, map} | {:error, :takendown}
  def track(did, %{temp_key: key, size: size, cid: cid, mime_type: mime}) do
    cid_str = CID.to_string(cid)

    case Repo.one(from(b in Blob, where: b.did == ^did and b.cid == ^cid_str)) do
      %{takedown_ref: ref} when not is_nil(ref) ->
        {:error, :takendown}

      _ ->
        Repo.insert_all(
          Blob,
          [
            %{
              did: did,
              cid: cid_str,
              mime_type: mime,
              size: size,
              temp_key: key,
              created_at: DateTime.utc_now()
            }
          ],
          on_conflict: [set: [temp_key: key]],
          conflict_target: [:did, :cid]
        )

        # already referenced by a record (re-upload): promote right away
        if Repo.exists?(from(rb in RecordBlob, where: rb.did == ^did and rb.blob_cid == ^cid_str)) do
          make_permanent(did, cid)
        end

        {:ok, %{"$type" => "blob", "ref" => cid, "mimeType" => mime, "size" => size}}
    end
  end

  @doc "Promotes every blob a set of records references (after a commit). Verifies size/mime against the row."
  @spec process_write_blobs(String.t(), [map]) :: :ok | {:error, term}
  def process_write_blobs(did, blobs) do
    Enum.reduce_while(blobs, :ok, fn blob, :ok ->
      case verify_and_make_permanent(did, blob) do
        :ok -> {:cont, :ok}
        e -> {:halt, e}
      end
    end)
  end

  defp verify_and_make_permanent(did, %{"ref" => %CID{} = cid, "size" => size, "mimeType" => mime}) do
    cid_str = CID.to_string(cid)

    case Repo.one(
           from(b in Blob, where: b.did == ^did and b.cid == ^cid_str and is_nil(b.takedown_ref))
         ) do
      nil ->
        {:error, {:blob_not_found, cid_str}}

      %{temp_key: nil} ->
        :ok

      row ->
        cond do
          size != row.size ->
            {:error, {:invalid_blob, "Expected blob size #{size}, got #{row.size}"}}

          not mime_matches?(mime, row.mime_type) ->
            {:error, {:invalid_blob, "Expected blob mime type #{mime}, got #{row.mime_type}"}}

          true ->
            make_permanent(did, cid)
        end
    end
  end

  defp mime_matches?(expected, actual) do
    expected == actual or
      (String.ends_with?(expected, "/*") and
         String.starts_with?(actual, String.trim_trailing(expected, "*")))
  end

  defp make_permanent(did, cid) do
    cid_str = CID.to_string(cid)

    case Repo.one(from(b in Blob, where: b.did == ^did and b.cid == ^cid_str, select: b.temp_key)) do
      nil ->
        :ok

      key ->
        with :ok <- Store.make_permanent(did, key, cid) do
          Repo.update_all(from(b in Blob, where: b.did == ^did and b.cid == ^cid_str),
            set: [temp_key: nil]
          )

          :ok
        end
    end
  end

  @doc "Metadata plus a byte stream for `getBlob`; taken-down blobs are not found."
  @spec get(String.t(), CID.t()) ::
          {:ok, %{size: non_neg_integer, mime_type: String.t(), stream: Enumerable.t()}}
          | {:error, :not_found}
  def get(did, %CID{} = cid) do
    cid_str = CID.to_string(cid)

    with %{takedown_ref: nil} = row <-
           Repo.one(from(b in Blob, where: b.did == ^did and b.cid == ^cid_str)),
         {:ok, stream} <- stream_blob(did, row, cid) do
      {:ok, %{size: row.size, mime_type: row.mime_type, stream: stream}}
    else
      _ -> {:error, :not_found}
    end
  end

  # A blob no record references yet is still in the temp half of the
  # two-phase write — the record is what promotes it. Reading has to reach it
  # there, or `com.atproto.sync.getBlob` answers BlobNotFound for an image the
  # author uploaded seconds ago. The pre-publish content check reads through
  # exactly that window, so without this every image post comes back
  # "moderation unavailable".
  defp stream_blob(did, %{temp_key: key}, cid) when is_binary(key) do
    case Store.stream(did, cid) do
      {:error, :not_found} -> Store.stream_temp(did, key)
      other -> other
    end
  end

  defp stream_blob(did, _row, cid), do: Store.stream(did, cid)

  @doc "`listBlobs`: referenced blob CIDs, ordered, with `since:` (repo rev) and `cursor:`."
  @spec list(String.t(), keyword) :: [String.t()]
  def list(did, opts \\ []) do
    limit = Keyword.get(opts, :limit, 500)

    q =
      from(rb in RecordBlob,
        where: rb.did == ^did,
        group_by: rb.blob_cid,
        select: rb.blob_cid,
        order_by: rb.blob_cid,
        limit: ^limit
      )

    q = if c = opts[:cursor], do: where(q, [rb], rb.blob_cid > ^c), else: q

    q =
      if since = opts[:since],
        do:
          from(rb in q,
            join: r in Record,
            on: r.did == rb.did and r.uri == rb.record_uri,
            where: r.rev > ^since
          ),
        else: q

    Repo.all(q)
  end

  @doc "`listMissingBlobs`: referenced blobs the store does not hold (no row, or still temp)."
  @spec missing(String.t(), keyword) :: [%{cid: String.t(), record_uri: String.t()}]
  def missing(did, opts \\ []) do
    limit = Keyword.get(opts, :limit, 500)

    q =
      from(rb in RecordBlob,
        left_join: b in Blob,
        on: b.did == rb.did and b.cid == rb.blob_cid and is_nil(b.temp_key),
        where: rb.did == ^did and is_nil(b.cid),
        order_by: rb.blob_cid,
        limit: ^limit,
        select: %{cid: rb.blob_cid, record_uri: rb.record_uri}
      )

    q = if c = opts[:cursor], do: where(q, [rb], rb.blob_cid > ^c), else: q
    Repo.all(q)
  end

  @spec count(String.t()) :: non_neg_integer
  def count(did),
    do: Repo.aggregate(from(b in Blob, where: b.did == ^did and is_nil(b.temp_key)), :count)

  @spec expected_count(String.t()) :: non_neg_integer
  def expected_count(did),
    do:
      Repo.one(
        from(rb in RecordBlob, where: rb.did == ^did, select: count(rb.blob_cid, :distinct))
      )

  @doc "Sets or clears a takedown, quarantining the object (upstream `updateBlobTakedownStatus`)."
  @spec set_takedown(String.t(), CID.t(), String.t() | nil) :: :ok
  def set_takedown(did, cid, ref) do
    Repo.update_all(from(b in Blob, where: b.did == ^did and b.cid == ^CID.to_string(cid)),
      set: [takedown_ref: ref]
    )

    if ref, do: Store.quarantine(did, cid), else: Store.unquarantine(did, cid)
    :ok
  end

  @doc """
  The reaper (DESIGN §4.4): objects the adapter holds that Postgres does not
  know are deleted; rows whose object is missing are returned for alerting
  (that is data loss, not cleanup). Never deletes a referenced blob.
  """
  @spec reap(String.t()) :: %{deleted: [String.t()], missing: [String.t()]}
  def reap(did) do
    known =
      from(b in Blob, where: b.did == ^did and is_nil(b.temp_key), select: b.cid)
      |> Repo.all()
      |> MapSet.new()

    stored = Store.list(did) |> Enum.map(&CID.to_string/1) |> MapSet.new()
    orphans = MapSet.difference(stored, known)
    missing = MapSet.difference(known, stored)
    Enum.each(orphans, &Store.delete(did, CID.parse!(&1)))
    %{deleted: MapSet.to_list(orphans), missing: MapSet.to_list(missing)}
  end
end
