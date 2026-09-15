defmodule Aerox.AppView.RepoSync do
  @moduledoc """
  Record-level synchronisation of each repository (Sync spec, "Reliable
  Repository Synchronization" and "Record-Level Synchronization").

  Every repo has a row in `actor_sync` with its last applied `rev`, commit CID,
  commit `data` root, and a status:

  * `synchronized` — every record of the current revision is indexed. A
    `#commit` whose `since` is the stored `rev` and whose `prevData` is the
    stored `data` is applied; one that does not follow on breaks the chain and
    the repo becomes `desynchronized`.
  * `desynchronized` — out of step; a backfill is (re)requested and events are
    dropped, because the backfill's CAR will contain them.
  * `in_progress` — a backfill is running. Events are queued in
    `actor_sync_pending` and replayed, in order, once the CAR has been indexed.

  Independently of status, events are ignored for accounts whose upstream
  hosting status is not active, when their `rev` is at or below the last one
  applied, and when their `rev` lies in the future beyond a clock-drift window.

  A repo seen for the first time through a commit with no `since` starts here,
  so it is applied and synchronised; one first seen mid-history is backfilled.

  The live path (`Aerox.AppView.Ingest.Indexer`, serialised per DID by the
  Broadway partition) and the backfill job take a per-DID lock for every state
  transition, so a backfill cannot finish between a live event's status check
  and its write. The backfill does not hold the lock while it fetches and
  indexes the CAR; live events see `in_progress` and queue meanwhile.
  """
  import Ecto.Query
  require Logger
  alias Aerox.ATProto.TID
  alias Aerox.AppView.{Backfill, Repo}
  alias Aerox.AppView.Schema.{Actor, ActorSync, ActorSyncPending}

  @locks Aerox.AppView.RepoSync.Locks
  @future_rev_tolerance_us 5 * 60 * 1_000_000

  @type state :: %{rev: String.t(), commit_cid: String.t(), data_cid: String.t()}

  @status_checks Aerox.AppView.RepoSync.StatusChecks
  @status_recheck_ms 60_000

  @doc "The supervised lock registry and status-check table; start them before anything that indexes."
  def child_spec(_) do
    %{
      id: __MODULE__,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           [
             Registry.child_spec(keys: :unique, name: @locks),
             %{
               id: @status_checks,
               start:
                 {Agent, :start_link,
                  [fn -> :ets.new(@status_checks, [:named_table, :public, :set]) end]}
             }
           ],
           [strategy: :one_for_one]
         ]}
    }
  end

  @doc "The repo's sync row, or nil."
  def get(did), do: Repo.get(ActorSync, did)

  # ---------------------------------------------------------------- live

  @doc """
  A verified `#commit`. `next` is the state the commit produces; `apply` writes
  its ops to the index and is only called when the commit follows on from the
  stored state (or starts the repo). Returns `:ok` when applied or queued.
  """
  @spec on_commit(String.t(), map, state, (-> any)) :: :ok | {:skip, term}
  def on_commit(did, body, next, apply) do
    with :ok <- not_future(next.rev),
         :ok <- active(did) do
      with_lock(did, fn -> commit_locked(did, body, next, apply) end)
    end
  end

  defp commit_locked(did, body, next, apply) do
    row = get(did)

    cond do
      row == nil and body["since"] == nil ->
        apply.()
        put(did, next, "synchronized")
        :ok

      row == nil ->
        desynchronize(did, nil, :first_seen_mid_history)

      row.repo_rev != nil and next.rev <= row.repo_rev ->
        {:skip, {:old_rev, next.rev, row.repo_rev}}

      row.status == "in_progress" ->
        enqueue(did, "#commit", next.rev, body)

      row.status == "desynchronized" ->
        Backfill.request(did)
        {:skip, :desynchronized}

      reason = chain_break(row, body) ->
        desynchronize(did, row, reason)

      true ->
        apply.()
        put(did, next, "synchronized")
        :ok
    end
  end

  @doc """
  A `#commit` that failed verification (a missing block, a bad signature, an
  op list that does not invert). Its ops are never applied, but the PDS did
  move the repo on, so whatever the event was meant to carry is now missing
  from the index: the repo is desynchronised and backfilled from the PDS's own
  CAR, which is verified on its own terms. Without this a broken last commit
  stays missing until the account happens to write again. During a backfill
  the failure is queued as a marker, so the replay resyncs unless the CAR
  already covers its rev.
  """
  @spec on_invalid_commit(String.t(), map, term) :: {:skip, term}
  def on_invalid_commit(did, %{"rev" => rev} = body, reason) do
    with :ok <- not_future(rev),
         :ok <- active(did) do
      with_lock(did, fn ->
        row = get(did)

        cond do
          row && row.repo_rev != nil && rev <= row.repo_rev ->
            {:skip, {:old_rev, rev, row.repo_rev}}

          row && row.status == "in_progress" ->
            enqueue(did, "#invalid", rev, body)
            {:skip, {:invalid_commit, reason}}

          row && row.status == "desynchronized" ->
            Backfill.request(did)
            {:skip, {:invalid_commit, reason}}

          true ->
            desynchronize(did, row, {:invalid_commit, reason})
        end
      end)
    end
  end

  @doc """
  A verified `#sync`: the repo's current commit, asserted. Matching the stored
  state it is a no-op; a newer revision (or the same revision with another
  commit) resets the repo, which means a backfill.
  """
  @spec on_sync(String.t(), map, state) :: :ok | {:skip, term}
  def on_sync(did, body, next) do
    with :ok <- not_future(next.rev),
         :ok <- active(did) do
      with_lock(did, fn ->
        row = get(did)

        cond do
          row == nil ->
            desynchronize(did, nil, :first_seen_by_sync)

          row.repo_rev != nil and next.rev < row.repo_rev ->
            {:skip, {:old_rev, next.rev, row.repo_rev}}

          # a confirmation of what we hold: nothing to do
          row.repo_rev == next.rev and row.commit_cid == next.commit_cid ->
            :ok

          row.status == "in_progress" ->
            enqueue(did, "#sync", next.rev, body)

          row.status == "desynchronized" ->
            Backfill.request(did)
            {:skip, :desynchronized}

          true ->
            desynchronize(did, row, {:sync_reset, next.rev})
        end
      end)
    end
  end

  # -------------------------------------------------------------- backfill

  @doc "The backfill job is starting: events from here on are queued."
  def begin_backfill(did) do
    with_lock(did, fn ->
      case get(did) do
        nil ->
          Repo.insert_all(ActorSync, [row(did, nil, "in_progress")])

        _ ->
          Repo.update_all(from(s in ActorSync, where: s.did == ^did),
            set: [status: "in_progress", updated_at: now()]
          )
      end

      :ok
    end)
  end

  @doc """
  The backfill has indexed the repo at `car_state`. Queued events are replayed
  in order through `replay` (which verifies and applies a queued `#commit` body
  and returns the state it produced); the repo is synchronised if they all
  follow on, and `:resync` is returned — the repo left `desynchronized` — if
  one does not.
  """
  @spec finish_backfill(String.t(), state, (map -> {:ok, state} | {:error, term})) ::
          :ok | :resync
  def finish_backfill(did, car_state, replay) do
    with_lock(did, fn ->
      pending =
        Repo.all(from(p in ActorSyncPending, where: p.did == ^did, order_by: [asc: p.seq]))

      result =
        Enum.reduce_while(pending, {:ok, car_state}, fn p, {:ok, state} ->
          body = :erlang.binary_to_term(p.body)

          cond do
            p.rev <= state.rev ->
              {:cont, {:ok, state}}

            p.type == "#commit" and follows?(state, body) ->
              case replay.(body) do
                {:ok, next} -> {:cont, {:ok, next}}
                {:error, reason} -> {:halt, {:broken, state, {:replay_failed, reason}}}
              end

            p.type == "#commit" ->
              {:halt, {:broken, state, :chain_break_in_queue}}

            true ->
              {:halt, {:broken, state, {:sync_reset, p.rev}}}
          end
        end)

      Repo.delete_all(from(p in ActorSyncPending, where: p.did == ^did))

      case result do
        {:ok, state} ->
          put(did, state, "synchronized")
          :ok

        {:broken, state, reason} ->
          Logger.info("appview: #{did} desynchronized during backfill: #{inspect(reason)}")
          put(did, state, "desynchronized")
          :resync
      end
    end)
  end

  @doc "The backfill failed; the repo waits, desynchronised, for the next attempt."
  def fail_backfill(did) do
    with_lock(did, fn ->
      Repo.delete_all(from(p in ActorSyncPending, where: p.did == ^did))

      Repo.update_all(from(s in ActorSync, where: s.did == ^did),
        set: [status: "desynchronized", updated_at: now()]
      )

      :ok
    end)
  end

  # ------------------------------------------------------------- helpers

  @doc "Does a `#commit` body follow on from `state` (its `since` and `prevData`)?"
  def follows?(%{rev: rev, data_cid: data}, body) do
    chain_break(%{repo_rev: rev, data_cid: data}, body) == nil
  end

  defp chain_break(%{repo_rev: rev, data_cid: data}, body) do
    prev_data = body["prevData"] && to_string(body["prevData"])

    cond do
      rev != nil and body["since"] != rev -> {:since_mismatch, body["since"], rev}
      data != nil and prev_data != data -> {:prev_data_mismatch, prev_data, data}
      true -> nil
    end
  end

  defp desynchronize(did, row, reason) do
    Logger.info("appview: #{did} desynchronized: #{inspect(reason)}")

    if row do
      Repo.update_all(from(s in ActorSync, where: s.did == ^did),
        set: [status: "desynchronized", updated_at: now()]
      )
    else
      Repo.insert_all(ActorSync, [row(did, nil, "desynchronized")], on_conflict: :nothing)
    end

    Backfill.request(did)
    {:skip, {:desynchronized, reason}}
  end

  defp enqueue(did, type, rev, body) do
    Repo.insert_all(ActorSyncPending, [
      %{
        did: did,
        seq: body["seq"] || 0,
        type: type,
        rev: rev,
        body: :erlang.term_to_binary(body),
        inserted_at: now()
      }
    ])

    :ok
  end

  defp put(did, state, status) do
    Repo.insert_all(ActorSync, [row(did, state, status)],
      on_conflict: {:replace, [:commit_cid, :repo_rev, :data_cid, :status, :updated_at]},
      conflict_target: :did
    )
  end

  defp row(did, state, status) do
    %{
      did: did,
      commit_cid: state && state.commit_cid,
      repo_rev: state && state.rev,
      data_cid: state && state.data_cid,
      status: status,
      updated_at: now()
    }
  end

  defp not_future(rev) do
    now = System.os_time(:microsecond)

    if TID.timestamp(rev) > now + @future_rev_tolerance_us,
      do: {:skip, {:future_rev, rev}},
      else: :ok
  end

  defp active(did) do
    case Repo.one(from(a in Actor, where: a.did == ^did, select: a.upstream_status)) do
      status when status in [nil, "active"] -> :ok
      status -> recheck_status(did, status)
    end
  end

  # An event for an account we hold as inactive. The `#account` that said so
  # may be stale: an account that migrated away from a PDS is deactivated there
  # after its new host went live, and a new host that never announces the
  # activation leaves that the last word — the indigo relay forwards the new
  # host's commits without re-announcing the status it re-checked. So the
  # account's current PDS is asked, at most once a minute per DID
  # (VERIFICATION §7.4, aerox → rsky).
  defp recheck_status(did, status) do
    now = System.monotonic_time(:millisecond)

    due? =
      case :ets.lookup(@status_checks, did) do
        [{^did, at}] -> now - at >= @status_recheck_ms
        [] -> true
      end

    with true <- due?,
         true <- :ets.insert(@status_checks, {did, now}),
         {:ok, "active"} <- Backfill.fetch_repo_status(did) do
      Logger.info("appview: #{did} is active again at its PDS (was #{status})")
      Aerox.AppView.Indexing.update_actor_status(did, upstream_status: "active")
      :ok
    else
      _ -> {:skip, {:inactive, status}}
    end
  end

  defp with_lock(did, fun) do
    acquire(did, System.monotonic_time(:millisecond) + 60_000)

    try do
      fun.()
    after
      Registry.unregister(@locks, did)
    end
  end

  defp acquire(did, deadline) do
    case Registry.register(@locks, did, nil) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, _}} ->
        if System.monotonic_time(:millisecond) > deadline,
          do: raise("appview: timed out waiting for the sync lock of #{did}")

        Process.sleep(5)
        acquire(did, deadline)
    end
  end

  defp now, do: DateTime.utc_now()
end
