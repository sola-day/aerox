defmodule Aerox.Jetstream.Compactor do
  @moduledoc """
  Physical compaction of the sealed archive (docs/README.md §3.3). A pass takes
  the tombstones above the watermark whose seq the sealed archive already
  covers — record tombstones (deletes, updates) and DID tombstones (account
  deletions, `#sync`) — and rewrites each affected sealed segment without the
  `create`/`update`/`create_resync` rows they supersede: same record (or DID),
  lower seq. Delete, identity, account and sync rows always stay. Blocks keep
  their positions and seq bounds; a rewrite goes to a temporary file, is
  synced, and replaces the segment by rename before the manifest learns of it.

  Runs every `compaction_interval_ms`, early once `compaction_tombstone_cap`
  tombstones wait, and on demand. Archive rewrites of any kind (timestamp
  imports too) run through `exclusive/1` so two never race on one file.
  """
  use GenServer
  import Ecto.Query
  require Logger
  alias Aerox.Jetstream.{Config, Event, Gloom, Manifest, Repo, Segment, Store}
  alias Aerox.Jetstream.Schema.Tombstone

  @cap_check_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Runs a pass now; `{:ok, %{segments: n, rows_dropped: n, watermark: seq}}`."
  def run_now, do: GenServer.call(__MODULE__, :run, :infinity)

  @doc "Runs an archive rewrite serialised with compaction."
  def exclusive(fun), do: GenServer.call(__MODULE__, {:exclusive, fun}, :infinity)

  @doc "When the next scheduled pass starts (for archive `Cache-Control`), or nil."
  def next_compaction_at do
    case Store.get("next_compaction_at") do
      nil -> nil
      us -> DateTime.from_unix!(us, :microsecond)
    end
  end

  @impl true
  def init(_) do
    schedule(Config.compaction_interval_ms())
    Process.send_after(self(), :cap_check, @cap_check_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_call(:run, _from, state), do: {:reply, pass(), state}
  def handle_call({:exclusive, fun}, _from, state), do: {:reply, fun.(), state}

  @impl true
  def handle_info(:scheduled, state) do
    _ = pass()
    schedule(Config.compaction_interval_ms())
    {:noreply, state}
  end

  def handle_info(:cap_check, state) do
    Process.send_after(self(), :cap_check, @cap_check_ms)
    if Repo.aggregate(Tombstone, :count) >= Config.compaction_tombstone_cap(), do: pass()
    {:noreply, state}
  end

  defp schedule(0), do: Store.put("next_compaction_at", nil)

  defp schedule(ms) do
    Process.send_after(self(), :scheduled, ms)
    Store.put("next_compaction_at", System.os_time(:microsecond) + ms * 1000)
  end

  @doc false
  def pass do
    watermark = Store.get("compaction_seq", 0)
    tip = Manifest.sealed_tip()

    tombstones =
      from(t in Tombstone,
        where: t.seq > ^watermark and t.seq <= ^tip,
        select: {t.seq, t.scope, t.key}
      )
      |> Repo.all()

    if tombstones == [] do
      {:ok, %{segments: 0, rows_dropped: 0, watermark: watermark}}
    else
      {uris, dids} =
        Enum.reduce(tombstones, {%{}, %{}}, fn
          {seq, "uri", key}, {u, d} -> {Map.update(u, key, seq, &max(&1, seq)), d}
          {seq, "did", key}, {u, d} -> {u, Map.update(d, key, seq, &max(&1, seq))}
        end)

      candidates = (Map.keys(dids) ++ Enum.map(Map.keys(uris), &uri_did/1)) |> Enum.uniq()
      max_ts = tombstones |> Enum.map(&elem(&1, 0)) |> Enum.max()

      superseded? = fn e ->
        Event.materialization?(e) and
          (((ts = uris["at://#{e.did}/#{e.collection}/#{e.rkey}"]) != nil and e.seq < ts) or
             ((ts = dids[e.did]) != nil and e.seq < ts))
      end

      {segments, dropped} =
        Manifest.sealed()
        |> Enum.filter(
          &(&1.header.min_seq < max_ts and
              Enum.any?(candidates, fn did -> Gloom.member?(&1.segment_bloom, did) end))
        )
        |> Enum.reduce({0, 0}, fn seg, {n, d} ->
          case rewrite(seg, &(not superseded?.(&1))) do
            {:ok, rows} -> {n + 1, d + rows}
            :unchanged -> {n, d}
          end
        end)

      Store.put("compaction_seq", max_ts)
      Repo.delete_all(from(t in Tombstone, where: t.seq <= ^max_ts))

      if segments > 0,
        do:
          Logger.info(
            "jetstream: compaction rewrote #{segments} segments, dropped #{dropped} rows"
          )

      {:ok, %{segments: segments, rows_dropped: dropped, watermark: max_ts}}
    end
  end

  @doc "Rewrites one sealed segment through `keep?`; publishes the new file to the manifest."
  def rewrite(seg, keep?, transform \\ & &1) do
    file = File.read!(seg.path)
    parsed = %{seg | blocks: seg.blocks}

    case Segment.rewrite(file, parsed, keep?, transform) do
      {:unchanged, _} ->
        :unchanged

      {:ok, bin, _header, changed} ->
        tmp = seg.path <> ".tmp"
        {:ok, fd} = :file.open(tmp, [:write, :binary, :raw])
        :ok = :file.write(fd, bin)
        :ok = :file.datasync(fd)
        :ok = :file.close(fd)
        :ok = File.rename(tmp, seg.path)
        {:ok, meta, size} = Manifest.read_metadata(seg.path)
        :ok = Manifest.put_sealed(seg.idx, seg.path, meta, size)
        {:ok, changed}
    end
  end

  defp uri_did("at://" <> rest), do: rest |> String.split("/") |> hd()
end
