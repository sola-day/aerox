defmodule Aerox.Jetstream.Cursor do
  @moduledoc """
  Subscribe cursors (upstream `subscribe.ResolveCursor`). A value below 10^15
  is a seq, anything above a unix-microseconds timestamp translated to the
  first seq witnessed at or after it. No cursor, or one in the future, is the
  live tip. A cursor below the lookback floor is clamped up to it — except a
  seq cursor on the v2 endpoint, which is refused (`CursorTooOld`) so an
  archive-backfilling client can re-plan rather than skip a gap.
  """
  import Ecto.Query
  alias Aerox.Jetstream.{Block, Config, Manifest, Repo, Tail, Writer}
  alias Aerox.Jetstream.Schema.EventRow

  @seq_max 1_000_000_000_000_000

  @type plan :: %{mode: :live | :seq | :time, start: non_neg_integer, clamped: boolean}

  @spec resolve(String.t() | nil, boolean) ::
          {:ok, plan} | {:error, :invalid | {:too_old, String.t()}}
  def resolve(raw, v2?)
  def resolve(nil, _), do: {:ok, %{mode: :live, start: Tail.tip(), clamped: false}}
  def resolve("", _), do: {:ok, %{mode: :live, start: Tail.tip(), clamped: false}}

  def resolve(raw, v2?) do
    case Integer.parse(raw) do
      {n, ""} when n >= 0 and n < @seq_max -> seq(n, v2?)
      {n, ""} when n >= @seq_max -> time(n)
      _ -> {:error, :invalid}
    end
  end

  defp seq(n, v2?) do
    next = Writer.next_seq()

    if n >= next do
      {:ok, %{mode: :live, start: next, clamped: true}}
    else
      start = max(n, 1)
      floor = Manifest.lookback_floor(Config.lookback_ms())

      cond do
        start >= floor or floor == 0 ->
          {:ok, %{mode: :seq, start: start, clamped: start != n}}

        v2? ->
          {:error,
           {:too_old, "cursor #{n} below lookback floor #{floor}; re-backfill from your last seq"}}

        true ->
          {:ok, %{mode: :seq, start: floor, clamped: true}}
      end
    end
  end

  defp time(us) do
    if us > System.os_time(:microsecond) do
      {:ok, %{mode: :live, start: Tail.tip(), clamped: true}}
    else
      {start, clamped} = seq_for_time(us)
      floor = Manifest.lookback_floor(Config.lookback_ms())
      {start, clamped} = if floor > 0 and start < floor, do: {floor, true}, else: {start, clamped}
      {:ok, %{mode: :time, start: max(start, 1), clamped: clamped}}
    end
  end

  # the first seq witnessed at or after `us`: sealed segments, the active
  # segment's blocks, then pending rows; past everything, the tip
  defp seq_for_time(us) do
    sealed = Manifest.sealed()

    case sealed do
      [first | _] when us <= first.header.min_witnessed_at ->
        {first.header.min_seq, true}

      _ ->
        from_blocks(Enum.map(sealed, &{&1.path, &1.blocks, &1.header.checksum}), us) ||
          from_blocks(active_blocks(), us) ||
          {Repo.one(from(e in EventRow, where: e.witnessed_at >= ^us, select: min(e.seq))) ||
             Writer.next_seq(), false}
    end
  end

  defp active_blocks do
    case Manifest.active() do
      %{path: path, blocks: blocks} -> [{path, blocks, 0}]
      _ -> []
    end
  end

  defp from_blocks(segments, us) do
    Enum.find_value(segments, fn {path, blocks, checksum} ->
      case Enum.find(blocks, &(&1.event_count > 0 and &1.max_witnessed_at >= us)) do
        nil ->
          nil

        info ->
          with {:ok, frame} <- Tail.read_frame(path, info, checksum),
               {:ok, events, _} <- Block.decompress(frame),
               %{seq: seq} <- Enum.find(events, &(&1.witnessed_at >= us)) do
            {seq, false}
          else
            _ -> {info.max_seq, false}
          end
      end
    end)
  end
end
