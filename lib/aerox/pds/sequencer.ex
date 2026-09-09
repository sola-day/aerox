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
  import Ecto.Query
  alias Aerox.PDS.Repo
  alias Aerox.PDS.Schema.RepoSeq
  alias Aerox.PDS.Sequencer.Events

  @topic "firehose"

  def topic, do: @topic

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  def start_link(opts \\ []) do
    Aerox.Sequencer.start_link(
      name: Keyword.get(opts, :name, __MODULE__),
      repo: Repo,
      schema: RepoSeq,
      topic: @topic,
      unboxed: Application.get_env(:aerox, __MODULE__, [])[:unboxed] || false
    )
  end

  @doc "Sequences one or more event rows; returns their seq numbers in order."
  @spec sequence([map] | map, GenServer.server()) :: {:ok, [pos_integer]}
  def sequence(rows, server \\ __MODULE__)
  def sequence(row, server) when is_map(row), do: sequence([row], server)

  def sequence(rows, server) when is_list(rows), do: Aerox.Sequencer.sequence(server, rows)

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
  def current, do: Aerox.Sequencer.current(Repo, RepoSeq)

  @doc "The first row after `cursor`."
  def next_after(cursor), do: Aerox.Sequencer.next_after(Repo, RepoSeq, cursor)

  @doc "The earliest row sequenced at or after `time`."
  def earliest_after_time(time), do: Aerox.Sequencer.earliest_after_time(Repo, RepoSeq, time)

  @doc "Non-invalidated rows in `(after_seq, ∞)`, oldest first, at most `limit`."
  @spec range(pos_integer | nil, pos_integer) :: [map]
  def range(after_seq, limit), do: Aerox.Sequencer.range(Repo, RepoSeq, after_seq, limit)
end
