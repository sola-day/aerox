defmodule Aerox.Jetstream.Writer do
  @moduledoc """
  The single writer of the Jetstream log (upstream `internal/ingest.Writer`).

  `append/2` stamps rows with `witnessed_at` (monotonic with seq) and any
  imported display time, takes their seqs from `event_seq`, and commits them
  — with the relay cursor that produced them and the tombstones they imply —
  in one transaction to `event`, then tells subscribers. Rows are readable
  from that moment.

  Pending rows become a block when `max_events_per_block` have accumulated or
  the oldest has waited `block_max_age_ms`: the block is compressed, appended
  to the active segment file and synced, published to the manifest, and only
  then removed from `event`, so a reader always finds a row in one place or
  the other. When the active file passes `segment_bytes` it is sealed in place
  (footer appended, header written) and a new active segment begins.

  Recovery walks the active file, cuts a torn tail, and drops pending rows the
  file already holds.
  """
  use GenServer
  import Ecto.Query
  require Logger
  alias Aerox.ATProto.CID
  alias Aerox.Jetstream.{Block, Config, Event, Manifest, Repo, Segment, Store}
  alias Aerox.Jetstream.Schema.{EventRow, TimestampRule, Tombstone}

  @topic "jetstream:appended"
  @tick_ms 1_000

  def topic, do: @topic

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Appends rows (`%Event{}` without seqs) in order; `cursor:` is the upstream
  relay seq they came from. Returns the rows with their seqs.
  """
  @spec append([Event.t()], keyword) :: {:ok, [Event.t()]} | {:error, term}
  def append(rows, opts \\ []), do: GenServer.call(__MODULE__, {:append, rows, opts}, 60_000)

  @doc "Flushes pending rows into a block now (tests, shutdown)."
  def flush, do: GenServer.call(__MODULE__, :flush, 60_000)

  @doc "Flushes and seals the active segment now (upstream force-rotate), if it holds any block."
  def rotate, do: GenServer.call(__MODULE__, :rotate, 60_000)

  @doc "The next seq the log will assign (upstream `NextSeq`); the live tip is one below."
  def next_seq do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT CASE WHEN is_called THEN last_value + 1 ELSE last_value END FROM event_seq"
      )

    n
  end

  # ------------------------------------------------------------- server

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    dir = Config.segments_dir()
    File.mkdir_p!(dir)
    state = recover(dir)
    Process.send_after(self(), :tick, @tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_call({:append, rows, opts}, _from, state) do
    case do_append(rows, opts, state) do
      {:ok, appended, state} ->
        state = maybe_flush(state)
        {:reply, {:ok, appended}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:flush, _from, state), do: {:reply, :ok, flush_all(state)}

  def handle_call(:rotate, _from, state) do
    state = flush_all(state)
    state = if state.blocks == [], do: state, else: seal(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)

    state =
      case oldest_pending_us() do
        nil ->
          state

        oldest ->
          if System.os_time(:microsecond) - oldest >= Config.block_max_age_ms() * 1000,
            do: flush_block(state),
            else: state
      end

    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state[:fd], do: :file.close(state.fd)
    :ok
  end

  # -------------------------------------------------------------- append

  defp do_append([], _opts, state), do: {:ok, [], state}

  defp do_append(rows, opts, state) do
    now = System.os_time(:microsecond)
    witnessed = max(now, state.last_witnessed)
    rows = stamp(rows, witnessed)

    Repo.transaction(fn ->
      %{rows: seqs} =
        Repo.query!("SELECT nextval('event_seq') FROM generate_series(1, $1)", [length(rows)])

      rows = Enum.zip_with(rows, seqs, fn row, [seq] -> %{row | seq: seq} end)

      Repo.insert_all(EventRow, Enum.map(rows, &to_row/1))

      case Enum.flat_map(rows, &tombstones/1) do
        [] -> :ok
        ts -> Repo.insert_all(Tombstone, ts)
      end

      if cursor = opts[:cursor], do: Store.put("relay_cursor", cursor)
      rows
    end)
    |> case do
      {:ok, rows} ->
        max_seq = List.last(rows).seq
        Phoenix.PubSub.broadcast(Aerox.PubSub, @topic, {:jetstream_appended, max_seq})
        {:ok, rows, %{state | last_witnessed: witnessed, pending: state.pending + length(rows)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Every row of one append shares the witnessed time; operator-imported
  # display times apply to rows that materialize a record (upstream: rows
  # appended after rule activation are stamped before they are readable).
  defp stamp(rows, witnessed) do
    rows = Enum.map(rows, &%{&1 | witnessed_at: witnessed})
    uris = for r <- rows, Event.materialization?(r), uniq: true, do: uri(r)

    rules =
      if uris == [] do
        %{}
      else
        from(t in TimestampRule, where: t.uri in ^uris)
        |> Repo.all()
        |> Enum.group_by(& &1.uri)
      end

    if rules == %{} do
      rows
    else
      Enum.map(rows, fn r ->
        with true <- Event.materialization?(r),
             [_ | _] = candidates <- rules[uri(r)] do
          cid = CID.to_string(CID.for_cbor(r.payload))

          case Enum.find(candidates, &(&1.cid == cid)) || Enum.find(candidates, &(&1.cid == "")) do
            nil -> r
            rule -> %{r | indexed_at: rule.indexed_at}
          end
        else
          _ -> r
        end
      end)
    end
  end

  defp uri(r), do: "at://#{r.did}/#{r.collection}/#{r.rkey}"

  # docs/README.md §3.3: record tombstones from deletes and updates, DID
  # tombstones from account deletions and #sync
  defp tombstones(%Event{kind: k} = r) when k in [:delete, :update],
    do: [%{seq: r.seq, scope: "uri", key: uri(r)}]

  defp tombstones(%Event{kind: :sync} = r), do: [%{seq: r.seq, scope: "did", key: r.did}]

  defp tombstones(%Event{kind: :account} = r) do
    case Aerox.ATProto.DagCBOR.decode(r.payload) do
      {:ok, %{"active" => false, "status" => "deleted"}} ->
        [%{seq: r.seq, scope: "did", key: r.did}]

      _ ->
        []
    end
  end

  defp tombstones(_), do: []

  defp to_row(%Event{} = e) do
    %{
      seq: e.seq,
      witnessed_at: e.witnessed_at,
      indexed_at: e.indexed_at,
      kind: Event.kind_code(e.kind),
      did: e.did,
      collection: e.collection,
      rkey: e.rkey,
      rev: e.rev,
      payload: e.payload
    }
  end

  @doc false
  def from_row(%EventRow{} = r) do
    {:ok, kind} = Event.kind_from_code(r.kind)

    %Event{
      seq: r.seq,
      witnessed_at: r.witnessed_at,
      indexed_at: r.indexed_at,
      kind: kind,
      did: r.did,
      collection: r.collection,
      rkey: r.rkey,
      rev: r.rev,
      payload: r.payload
    }
  end

  defp oldest_pending_us do
    Repo.one(from(e in EventRow, select: min(e.witnessed_at)))
  end

  # --------------------------------------------------------------- flush

  defp maybe_flush(state) do
    if state.pending >= Config.max_events_per_block(),
      do: maybe_flush(flush_block(state)),
      else: state
  end

  defp flush_all(state) do
    if state.pending > 0, do: flush_all(flush_block(state)), else: state
  end

  defp flush_block(state) do
    rows =
      from(e in EventRow, order_by: [asc: e.seq], limit: ^Config.max_events_per_block())
      |> Repo.all()
      |> Enum.map(&from_row/1)

    case rows do
      [] ->
        %{state | pending: 0}

      rows ->
        {frame, usize} = Block.compress(rows)
        :ok = :file.pwrite(state.fd, state.size, Segment.framed(frame))
        :ok = :file.datasync(state.fd)

        info =
          Map.merge(
            %{
              offset: state.size,
              compressed_size: byte_size(frame),
              uncompressed_size: usize,
              event_count: length(rows)
            },
            Segment.bounds(rows)
          )

        blocks = state.blocks ++ [{info, Segment.summarize(rows)}]
        :ok = Manifest.set_active(state.idx, state.path, Enum.map(blocks, &elem(&1, 0)))

        max_seq = info.max_seq
        {deleted, _} = Repo.delete_all(from(e in EventRow, where: e.seq <= ^max_seq))

        state = %{
          state
          | blocks: blocks,
            size: state.size + 8 + byte_size(frame),
            pending: max(state.pending - deleted, 0)
        }

        if state.size >= Config.segment_bytes(), do: seal(state), else: state
    end
  end

  # ---------------------------------------------------------------- seal

  defp seal(state) do
    {footer, header_bin, header} = Segment.build_footer(state.blocks, state.size)
    :ok = :file.pwrite(state.fd, state.size, footer)
    :ok = :file.pwrite(state.fd, 0, header_bin)
    :ok = :file.datasync(state.fd)
    :ok = :file.close(state.fd)

    {:ok, parsed} =
      Segment.parse_footer(
        Map.delete(header, :checksum) |> Map.put(:checksum, header.checksum),
        footer
      )

    :ok = Manifest.put_sealed(state.idx, state.path, parsed, state.size + byte_size(footer))

    Logger.info(
      "jetstream: sealed #{Path.basename(state.path)} (#{header.block_count} blocks, #{header.event_count} events)"
    )

    open_active(state.idx + 1, state)
  end

  defp open_active(idx, state) do
    path = Path.join(Config.segments_dir(), Segment.filename(idx))
    {:ok, fd} = :file.open(path, [:read, :write, :binary, :raw])
    :ok = :file.pwrite(fd, 0, Segment.active_header())
    :ok = :file.datasync(fd)
    :ok = Manifest.set_active(idx, path, [])
    %{state | idx: idx, path: path, fd: fd, size: Segment.header_bytes(), blocks: []}
  end

  # ------------------------------------------------------------ recovery

  defp recover(dir) do
    sealed = Manifest.sealed()

    next_idx =
      case sealed do
        [] -> 0
        _ -> List.last(sealed).idx + 1
      end

    base = %{idx: nil, path: nil, fd: nil, size: 0, blocks: [], pending: 0, last_witnessed: 0}

    active_path = Path.join(dir, Segment.filename(next_idx))

    state =
      if File.exists?(active_path) do
        {:ok, bin} = File.read(active_path)
        {:ok, blocks, end_offset} = Segment.walk_active(bin)
        {:ok, fd} = :file.open(active_path, [:read, :write, :binary, :raw])
        # anything past the last whole frame is a torn write (or a half-written footer)
        {:ok, _} = :file.position(fd, end_offset)
        :ok = :file.truncate(fd)
        :ok = :file.pwrite(fd, 0, Segment.active_header())
        :ok = :file.datasync(fd)

        {pairs, _} =
          Enum.map_reduce(blocks, Segment.header_bytes(), fn b, offset ->
            info =
              Map.merge(
                %{
                  offset: offset,
                  compressed_size: byte_size(b.frame),
                  uncompressed_size: b.uncompressed_size,
                  event_count: length(b.events)
                },
                Segment.bounds(b.events)
              )

            {{info, Segment.summarize(b.events)}, offset + 8 + byte_size(b.frame)}
          end)

        :ok = Manifest.set_active(next_idx, active_path, Enum.map(pairs, &elem(&1, 0)))
        %{base | idx: next_idx, path: active_path, fd: fd, size: end_offset, blocks: pairs}
      else
        open_active(next_idx, base)
      end

    # rows the archive already holds were flushed before a crash cut the delete
    tip = Manifest.archive_tip()
    Repo.delete_all(from(e in EventRow, where: e.seq <= ^tip))

    pending = Repo.aggregate(EventRow, :count)
    last_w = Repo.one(from(e in EventRow, select: max(e.witnessed_at))) || 0

    last_w =
      max(
        last_w,
        case Manifest.sealed() do
          [] -> 0
          segs -> List.last(segs).header.max_witnessed_at
        end
      )

    %{state | pending: pending, last_witnessed: last_w}
  end
end
