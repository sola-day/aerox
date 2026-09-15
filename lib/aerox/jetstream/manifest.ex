defmodule Aerox.Jetstream.Manifest do
  @moduledoc """
  What the archive holds, readable by every process without touching disk
  (upstream `internal/manifest`): each sealed segment's header, block index,
  DID blooms and collection index, and the blocks already flushed into the
  active segment. Kept in a protected ETS table owned by this process; the
  writer and the compactor publish changes through it.
  """
  use GenServer
  require Logger
  alias Aerox.Jetstream.{Config, Segment}

  @table __MODULE__

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  # ------------------------------------------------------------- reading

  @doc "Sealed segments in index order."
  def sealed do
    @table
    |> :ets.match_object({{:sealed, :_}, :_})
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.idx)
  end

  def segment(idx) do
    case :ets.lookup(@table, {:sealed, idx}) do
      [{_, meta}] -> {:ok, meta}
      [] -> :error
    end
  end

  @doc "The active segment: `%{idx, path, blocks}` (block infos), or nil before the writer starts."
  def active do
    case :ets.lookup(@table, :active) do
      [{_, a}] -> a
      [] -> nil
    end
  end

  @doc "The highest seq in any block, sealed or active (0 when none)."
  def archive_tip do
    active_tip =
      case active() do
        %{blocks: [_ | _] = blocks} -> blocks |> Enum.map(& &1.max_seq) |> Enum.max()
        _ -> 0
      end

    sealed_tip = sealed_tip()
    max(active_tip, sealed_tip)
  end

  @doc "The highest seq in the sealed archive (0 when none)."
  def sealed_tip do
    case sealed() do
      [] -> 0
      segs -> segs |> Enum.map(& &1.header.max_seq) |> Enum.max()
    end
  end

  @doc """
  Upstream `LookbackFloor`: the first seq of the oldest sealed segment still
  inside the lookback window (a clamp may give up to a segment extra, never
  less); `0` when nothing is sealed.
  """
  def lookback_floor(lookback_ms) do
    floor_us = System.os_time(:microsecond) - lookback_ms * 1000

    case sealed() do
      [] ->
        0

      segs ->
        case Enum.find(segs, &(&1.header.max_witnessed_at >= floor_us)) do
          nil -> List.last(segs).header.min_seq
          seg -> seg.header.min_seq
        end
    end
  end

  @doc """
  `{path, info, checksum}` of the first non-empty block whose max seq is at or
  above `seq`, across sealed then active blocks. `checksum` is the segment's
  (0 for the active one), so a reader can tell a file rewritten under it.
  """
  def block_at_or_after(seq) do
    from_sealed =
      Enum.find_value(sealed(), fn seg ->
        if seg.header.max_seq >= seq do
          Enum.find_value(seg.blocks, fn b ->
            if b.event_count > 0 and b.max_seq >= seq, do: {seg.path, b, seg.header.checksum}
          end)
        end
      end)

    from_sealed ||
      case active() do
        %{path: path, blocks: blocks} ->
          Enum.find_value(blocks, fn b ->
            if b.event_count > 0 and b.max_seq >= seq, do: {path, b, 0}
          end)

        _ ->
          nil
      end
  end

  # ------------------------------------------------------------ writing

  def put_sealed(idx, path, parsed, size),
    do: GenServer.call(__MODULE__, {:put_sealed, idx, path, parsed, size})

  def set_active(idx, path, blocks),
    do: GenServer.call(__MODULE__, {:set_active, idx, path, blocks})

  @doc "Re-reads every sealed segment from disk (after an out-of-band change)."
  def reload, do: GenServer.call(__MODULE__, :reload, :infinity)

  # ------------------------------------------------------------- server

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    load()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put_sealed, idx, path, parsed, size}, _from, state) do
    :ets.insert(@table, {{:sealed, idx}, Map.merge(parsed, %{idx: idx, path: path, size: size})})
    {:reply, :ok, state}
  end

  def handle_call({:set_active, idx, path, blocks}, _from, state) do
    :ets.insert(@table, {:active, %{idx: idx, path: path, blocks: blocks}})
    {:reply, :ok, state}
  end

  def handle_call(:reload, _from, state) do
    :ets.match_delete(@table, {{:sealed, :_}, :_})
    load()
    {:reply, :ok, state}
  end

  defp load do
    dir = Config.segments_dir()
    File.mkdir_p!(dir)

    for name <- File.ls!(dir), {:ok, idx} <- [Segment.parse_filename(name)] do
      path = Path.join(dir, name)

      case read_metadata(path) do
        {:ok, parsed, size} ->
          :ets.insert(
            @table,
            {{:sealed, idx}, Map.merge(parsed, %{idx: idx, path: path, size: size})}
          )

        {:error, :active} ->
          :ok

        {:error, reason} ->
          Logger.error("jetstream: unreadable segment #{name}: #{inspect(reason)}")
      end
    end

    :ok
  end

  @doc "A sealed file's metadata, reading only its header and footer."
  def read_metadata(path) do
    with {:ok, fd} <- :file.open(path, [:read, :binary, :raw]) do
      try do
        with {:ok, header_bin} <- :file.pread(fd, 0, Segment.header_bytes()),
             {:ok, h} <- Segment.decode_header(header_bin),
             {:ok, %{size: size}} <- File.stat(path),
             {:ok, footer} <- :file.pread(fd, h.footer_offset, size - h.footer_offset),
             true <-
               Segment.checksum(header_bin, footer) == h.checksum || {:error, :checksum_mismatch},
             {:ok, parsed} <- Segment.parse_footer(h, footer) do
          {:ok, parsed, size}
        end
      after
        :file.close(fd)
      end
    end
  end
end
