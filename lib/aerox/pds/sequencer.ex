defmodule Aerox.PDS.Sequencer do
  @moduledoc """
  The single writer of `repo_seq` (DESIGN §5.2, §5.3, §21.2): assigns `seq`,
  inserts, commits, then broadcasts — serialised in one GenServer so a
  subscriber can never observe a gap that later fills in. Calls are
  coalesced: `handle_call` enqueues and replies `:noreply`; a batch is
  flushed every `@flush_after` ms or `@max_batch` events as one insert, and
  every caller is replied to after the commit. `last_seq` is restored from
  `max(seq)` on start, never from 0.

  Broadcast: `{:firehose, rows}` on `Aerox.PubSub` topic `"firehose"`.
  """
  use GenServer
  import Ecto.Query
  alias Aerox.PDS.Repo
  alias Aerox.PDS.Schema.RepoSeq
  alias Aerox.PDS.Sequencer.Events

  @topic "firehose"
  @flush_after 10
  @max_batch 200

  def topic, do: @topic

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Sequences one or more event rows; returns their seq numbers in order."
  @spec sequence([map] | map, GenServer.server()) :: {:ok, [pos_integer]}
  def sequence(rows, server \\ __MODULE__)
  def sequence(row, server) when is_map(row), do: sequence([row], server)

  def sequence(rows, server) when is_list(rows),
    do: GenServer.call(server, {:sequence, rows}, 30_000)

  def sequence_commit(did, commit_data, server \\ __MODULE__),
    do: sequence([Events.commit(did, commit_data)], server)

  def sequence_identity(did, handle, server \\ __MODULE__),
    do: sequence([Events.identity(did, handle)], server)

  def sequence_account(did, status, server \\ __MODULE__),
    do: sequence([Events.account(did, status)], server)

  @doc "Upstream `sequenceAccountCreation`: identity, active, commit, sync — in that order."
  def sequence_account_creation(did, handle, commit_data, server \\ __MODULE__) do
    sequence(
      [
        Events.identity(did, handle),
        Events.account(did, "active"),
        Events.commit(did, commit_data),
        Events.sync(
          did,
          commit_data.cid,
          commit_data.rev,
          commit_data.new_blocks[commit_data.cid]
        )
      ],
      server
    )
  end

  @doc "Upstream `sequenceAccountActivation`: account, identity, sync."
  def sequence_account_activation(
        did,
        handle,
        status,
        {commit_cid, rev, commit_bytes},
        server \\ __MODULE__
      ) do
    sequence(
      [
        Events.account(did, status),
        Events.identity(did, handle),
        Events.sync(did, commit_cid, rev, commit_bytes)
      ],
      server
    )
  end

  @doc "Upstream `sequenceAccountDeletion`: the deleted event, then every earlier event of the DID is dropped."
  def sequence_account_deletion(did, server \\ __MODULE__) do
    {:ok, [seq]} = sequence([Events.account(did, "deleted")], server)
    Repo.delete_all(from(r in RepoSeq, where: r.did == ^did and r.seq != ^seq))
    {:ok, [seq]}
  end

  @doc "The latest seq, or nil."
  @spec current() :: pos_integer | nil
  def current, do: Repo.one(from(r in RepoSeq, select: max(r.seq)))

  @doc "The first row after `cursor`."
  def next_after(cursor),
    do: Repo.one(from(r in RepoSeq, where: r.seq > ^cursor, order_by: [asc: r.seq], limit: 1))

  @doc "The earliest row sequenced at or after `time`."
  def earliest_after_time(%DateTime{} = time),
    do:
      Repo.one(
        from(r in RepoSeq,
          where: r.sequenced_at >= ^time,
          order_by: [asc: r.sequenced_at, asc: r.seq],
          limit: 1
        )
      )

  @doc "Non-invalidated rows in `(after_seq, ∞)`, oldest first, at most `limit`."
  @spec range(pos_integer | nil, pos_integer) :: [map]
  def range(after_seq, limit) do
    q = from(r in RepoSeq, where: not r.invalidated, order_by: [asc: r.seq], limit: ^limit)
    q = if after_seq, do: where(q, [r], r.seq > ^after_seq), else: q
    q |> Repo.all() |> Enum.map(&Map.from_struct/1)
  end

  # The insert is the sequencer's own transaction on its own connection
  # (assign, insert, commit, then broadcast — DESIGN §5.3). Under the test
  # sandbox that connection must be a real one, or it would wait on the
  # test's single shared connection forever; `config :aerox, Aerox.PDS.Sequencer, unboxed: true`.
  defp insert_rows(rows) do
    run = fn -> Repo.transaction(fn -> Repo.insert_all(RepoSeq, rows) end) end

    if Application.get_env(:aerox, __MODULE__, [])[:unboxed],
      do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, run),
      else: run.()
  end

  # ---------------------------------------------------------------- server

  @impl true
  def init(_opts) do
    {:ok, %{last_seq: current() || 0, queue: [], timer: nil}}
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

    case insert_rows(rows) do
      {:ok, _} ->
        new_last = rows |> List.last() |> Map.fetch!(:seq)
        Enum.each(replies, fn {from, seqs} -> GenServer.reply(from, {:ok, seqs}) end)
        Phoenix.PubSub.broadcast(Aerox.PubSub, @topic, {:firehose, rows})
        %{state | queue: [], timer: nil, last_seq: new_last}

      {:error, reason} ->
        Enum.each(replies, fn {from, _} -> GenServer.reply(from, {:error, reason}) end)
        %{state | queue: [], timer: nil}
    end
  end
end
