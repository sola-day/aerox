defmodule Aerox.Jetstream.Tail do
  @moduledoc """
  Reads the log from a seq (upstream `subscribe.Tail.ReadFrom`): archive blocks
  (sealed segments, then the active segment's flushed blocks) for seqs they
  hold, pending rows in `event` above them. Returns at most one block's worth
  (or `limit` rows) and the cursor to continue from.
  """
  import Ecto.Query
  alias Aerox.Jetstream.{Block, Manifest, Repo, Writer}
  alias Aerox.Jetstream.Schema.EventRow

  @spec read_from(non_neg_integer, pos_integer) ::
          {:ok, [Aerox.Jetstream.Event.t()], non_neg_integer} | {:error, term}
  def read_from(cursor, limit, attempts \\ 5) do
    if cursor <= Manifest.archive_tip() do
      case Manifest.block_at_or_after(cursor) do
        {path, info, checksum} ->
          case read_block(path, info, checksum, cursor, limit) do
            # compaction replaced the file between the lookup and the read
            {:error, :rewritten} when attempts > 0 ->
              Process.sleep(10)
              read_from(cursor, limit, attempts - 1)

            other ->
              other
          end

        nil ->
          read_pending(cursor, limit)
      end
    else
      read_pending(cursor, limit)
    end
  end

  defp read_block(path, info, checksum, cursor, limit) do
    with {:ok, frame} <- read_frame(path, info, checksum),
         {:ok, events, _} <- Block.decompress(frame) do
      events = events |> Enum.filter(&(&1.seq >= cursor)) |> Enum.take(limit)

      next =
        case List.last(events) do
          nil -> info.max_seq + 1
          last -> last.seq + 1
        end

      {:ok, events, next}
    end
  end

  @doc """
  A block's zstd frame from its segment file; `{:error, :rewritten}` when the
  file's checksum is no longer `checksum` (pass nil to skip the check).
  """
  def read_frame(path, info, checksum \\ nil) do
    with {:ok, fd} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        with {:ok, <<_::binary-size(4), on_disk::little-64>>} <- :file.pread(fd, 0, 12),
             true <- checksum in [nil, on_disk] || {:error, :rewritten} do
          :file.pread(fd, info.offset + 8, info.compressed_size)
        end
      after
        :file.close(fd)
      end
    end
  end

  defp read_pending(cursor, limit) do
    rows =
      from(e in EventRow, where: e.seq >= ^cursor, order_by: [asc: e.seq], limit: ^limit)
      |> Repo.all()
      |> Enum.map(&Writer.from_row/1)

    case List.last(rows) do
      nil -> {:ok, [], cursor}
      last -> {:ok, rows, last.seq + 1}
    end
  end

  @doc "The seq a live subscriber starts at (the last assigned seq + 1)."
  def tip, do: Writer.next_seq()
end
