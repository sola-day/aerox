defmodule Aerox.Sequencer do
  @moduledoc """
  The single writer of a `repo_seq` table (DESIGN §5.2, §5.3, §21.2), shared
  by the PDS and the Relay, each with its own repo, table and PubSub topic.
  Assigns `seq`, inserts, commits, then broadcasts — serialised in one
  GenServer so a subscriber can never observe a gap that later fills in.
  Calls are coalesced: `handle_call` enqueues and replies `:noreply`; a
  batch is flushed every `@flush_after` ms or `@max_batch` events as one
  insert, and every caller is replied to after the commit. `last_seq` is
  restored from `max(seq)` on start, never from 0.

  Rows are `%{did, event_type, event}`; the sequencer adds `seq`,
  `invalidated: false` and `sequenced_at`. Broadcast: `{:firehose, rows}`
  on `Aerox.PubSub` at the configured topic.

  Under the test sandbox the insert must run on a real connection
  (`unboxed: true`), or it would wait on the test's shared connection.
  """
  use Boundary, top_level?: true, deps: [], exports: :all
  use GenServer
  import Ecto.Query

  @flush_after 10
  @max_batch 200

  @type config :: %{repo: module, schema: module, topic: String.t(), unboxed: boolean}

  @doc """
  Starts the sequencer as a small `rest_for_one` supervisor: a
  one-connection pool of `repo` (named `<name>.Pool`) and the single-writer
  GenServer registered as `name`, which routes its own queries through that
  pool. The flush must never queue behind request connections: callers hold a
  pool connection inside their own transaction while they wait on this
  process, so sharing the request pool inverts priorities under load (32
  writers on a pool of 5 starve the sequencer and every write times out).
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    repo = Keyword.fetch!(opts, :repo)
    pool = Module.concat(name, Pool)

    children = [
      Supervisor.child_spec({repo, [name: pool, pool_size: 1]}, id: :pool),
      %{
        id: :server,
        start:
          {GenServer, :start_link, [__MODULE__, Keyword.put(opts, :pool, pool), [name: name]]}
      }
    ]

    Supervisor.start_link(children, strategy: :rest_for_one)
  end

  @doc "Sequences event rows; returns their seq numbers in order."
  @spec sequence(GenServer.server(), [map]) :: {:ok, [pos_integer]} | {:error, term}
  def sequence(server, rows) when is_list(rows),
    do: GenServer.call(server, {:sequence, rows}, 30_000)

  # ------------------------------------------------------------- queries

  @doc "The latest seq, or nil."
  def current(repo, schema), do: repo.one(from(r in schema, select: max(r.seq)))

  @doc "The first row after `cursor`."
  def next_after(repo, schema, cursor),
    do: repo.one(from(r in schema, where: r.seq > ^cursor, order_by: [asc: r.seq], limit: 1))

  @doc "The earliest row sequenced at or after `time`."
  def earliest_after_time(repo, schema, %DateTime{} = time) do
    repo.one(
      from(r in schema,
        where: r.sequenced_at >= ^time,
        order_by: [asc: r.sequenced_at, asc: r.seq],
        limit: 1
      )
    )
  end

  @doc "Non-invalidated rows in `(after_seq, ∞)`, oldest first, at most `limit`."
  def range(repo, schema, after_seq, limit) do
    q = from(r in schema, where: not r.invalidated, order_by: [asc: r.seq], limit: ^limit)
    q = if after_seq, do: where(q, [r], r.seq > ^after_seq), else: q
    q |> repo.all() |> Enum.map(&Map.from_struct/1)
  end

  # -------------------------------------------------------------- server

  @impl true
  def init(opts) do
    repo = Keyword.fetch!(opts, :repo)
    schema = Keyword.fetch!(opts, :schema)

    repo.put_dynamic_repo(Keyword.fetch!(opts, :pool))

    {:ok,
     %{
       repo: repo,
       schema: schema,
       topic: Keyword.fetch!(opts, :topic),
       unboxed: Keyword.get(opts, :unboxed, false),
       last_seq: current(repo, schema) || 0,
       queue: [],
       timer: nil
     }}
  end

  @impl true
  def handle_call({:sequence, rows}, from, state) do
    state = %{state | queue: [{from, rows} | state.queue]}
    pending = Enum.reduce(state.queue, 0, fn {_, rows}, n -> n + length(rows) end)

    cond do
      pending >= @max_batch ->
        {:noreply, flush(state)}

      state.timer == nil ->
        {:noreply, %{state | timer: Process.send_after(self(), :flush, @flush_after)}}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:flush, state), do: {:noreply, flush(%{state | timer: nil})}

  defp flush(%{queue: []} = state), do: state

  defp flush(%{queue: queue, last_seq: last_seq, timer: timer} = state) do
    if timer, do: Process.cancel_timer(timer)
    batches = Enum.reverse(queue)
    now = DateTime.utc_now()

    {rows, _, replies} =
      Enum.reduce(batches, {[], last_seq, []}, fn {from, evts}, {acc, seq, replies} ->
        {numbered, seq} =
          Enum.map_reduce(evts, seq, fn evt, s ->
            {Map.merge(evt, %{seq: s + 1, invalidated: false, sequenced_at: now}), s + 1}
          end)

        {acc ++ numbered, seq, [{from, Enum.map(numbered, & &1.seq)} | replies]}
      end)

    case insert_rows(state, rows) do
      {:ok, _} ->
        new_last = rows |> List.last() |> Map.fetch!(:seq)
        Enum.each(replies, fn {from, seqs} -> GenServer.reply(from, {:ok, seqs}) end)
        Phoenix.PubSub.broadcast(Aerox.PubSub, state.topic, {:firehose, rows})
        %{state | queue: [], timer: nil, last_seq: new_last}

      {:error, reason} ->
        Enum.each(replies, fn {from, _} -> GenServer.reply(from, {:error, reason}) end)
        %{state | queue: [], timer: nil}
    end
  end

  # The insert is the sequencer's own transaction on its own connection
  # (assign, insert, commit, then broadcast — DESIGN §5.3).
  defp insert_rows(%{repo: repo, schema: schema, unboxed: unboxed}, rows) do
    run = fn -> repo.transaction(fn -> repo.insert_all(schema, rows) end) end
    if unboxed, do: Ecto.Adapters.SQL.Sandbox.unboxed_run(repo, run), else: run.()
  end
end
