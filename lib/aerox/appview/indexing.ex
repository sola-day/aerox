defmodule Aerox.AppView.Indexing do
  @moduledoc """
  Upstream `RecordProcessor` + `IndexingService` (DESIGN §15.2): writes the
  generic `record` row, dispatches to the collection's plugin, tracks
  duplicates, and writes notifications **in the same transaction** as the
  index write (§15.5). Updates are delete-then-insert, as upstream.
  """
  import Ecto.Query
  require Logger
  alias Aerox.ATProto.{Lexicon, Syntax}
  alias Aerox.AppView.{Plugins, Repo}
  alias Aerox.AppView.Schema.{Actor, ActorSync, DuplicateRecord, Notification, Record, ThreadMute}

  @doc "Index a record (create or update). `record` is the decoded data-model map."
  @spec index_record(String.t(), String.t(), map, DateTime.t(), keyword) :: :ok | {:error, term}
  def index_record(uri, cid, record, indexed_at, opts \\ []) do
    action = Keyword.get(opts, :action, :create)

    Repo.transaction(fn ->
      ensure_actor(uri_did(uri), indexed_at)

      Repo.insert_all(
        Record,
        [%{uri: uri, cid: cid, did: uri_did(uri), json: json(record), indexed_at: indexed_at}],
        on_conflict: {:replace, [:cid, :json, :indexed_at]},
        conflict_target: :uri
      )

      with {:ok, plugin} <- plugin_for(uri, record) do
        case action do
          :create -> insert(plugin, uri, cid, record, indexed_at, opts)
          :update -> update(plugin, uri, cid, record, indexed_at, opts)
        end
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Remove a record from the index."
  @spec delete_record(String.t(), keyword) :: :ok
  def delete_record(uri, opts \\ []) do
    cascading = Keyword.get(opts, :cascading, false)

    Repo.transaction(fn ->
      Repo.delete_all(from(r in Record, where: r.uri == ^uri))
      Repo.delete_all(from(d in DuplicateRecord, where: d.uri == ^uri))

      case Plugins.for_collection(uri_collection(uri)) do
        nil ->
          :ok

        plugin ->
          case plugin.delete(uri) do
            nil ->
              :ok

            deleted ->
              plugin.update_aggregates(deleted)

              if cascading do
                Repo.delete_all(from(d in DuplicateRecord, where: d.duplicate_of == ^uri))
                handle_notifs(plugin, %{deleted: deleted})
              else
                promote_duplicate(plugin, uri, deleted)
              end
          end
      end
    end)

    :ok
  end

  defp plugin_for(uri, record) do
    collection = uri_collection(uri)

    case Plugins.for_collection(collection) do
      nil ->
        {:error, :no_plugin}

      plugin ->
        if record["$type"] in [nil, collection] and valid?(collection, record),
          do: {:ok, plugin},
          else: {:error, :invalid_record}
    end
  end

  defp valid?(collection, record) do
    case Lexicon.validate_record(Lexicon.default_registry(), collection, record) do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.debug("appview: record fails lexicon validation #{collection}: #{inspect(reason)}")
        false
    end
  end

  defp insert(plugin, uri, cid, record, indexed_at, opts) do
    case plugin.insert(uri, cid, record, indexed_at) do
      nil ->
        # already indexed, or a duplicate of an existing record
        case plugin.find_duplicate(uri, record) do
          found when is_binary(found) and found != uri ->
            Repo.insert_all(
              DuplicateRecord,
              [%{uri: uri, cid: cid, duplicate_of: found, indexed_at: indexed_at}],
              on_conflict: :nothing,
              conflict_target: :uri
            )

            :ok

          _ ->
            :ok
        end

      inserted ->
        plugin.update_aggregates(inserted)
        unless opts[:disable_notifs], do: handle_notifs(plugin, %{inserted: inserted})
        :ok
    end
  end

  defp update(plugin, uri, cid, record, indexed_at, opts) do
    case plugin.find_duplicate(uri, record) do
      dupe when is_binary(dupe) ->
        Repo.update_all(from(d in DuplicateRecord, where: d.uri == ^uri),
          set: [cid: cid, duplicate_of: dupe, indexed_at: indexed_at]
        )

      nil ->
        Repo.delete_all(from(d in DuplicateRecord, where: d.uri == ^uri))
    end

    case plugin.delete(uri) do
      nil ->
        insert(plugin, uri, cid, record, indexed_at, opts)

      deleted ->
        plugin.update_aggregates(deleted)

        case plugin.insert(uri, cid, record, indexed_at) do
          nil ->
            Repo.rollback(:update_failed)

          inserted ->
            plugin.update_aggregates(inserted)

            unless opts[:disable_notifs],
              do: handle_notifs(plugin, %{inserted: inserted, deleted: deleted})

            :ok
        end
    end
  end

  # On delete, the oldest duplicate (if any) takes the deleted record's place.
  defp promote_duplicate(plugin, uri, deleted) do
    found =
      Repo.one(
        from(d in DuplicateRecord,
          join: r in Record,
          on: r.uri == d.uri,
          where: d.duplicate_of == ^uri,
          order_by: [asc: d.indexed_at],
          limit: 1,
          select: {d, r}
        )
      )

    case found do
      nil ->
        handle_notifs(plugin, %{deleted: deleted})

      {dup, record} ->
        inserted = plugin.insert(dup.uri, dup.cid, record.json, dup.indexed_at)
        if inserted, do: plugin.update_aggregates(inserted)
        Repo.delete_all(from(d in DuplicateRecord, where: d.uri == ^dup.uri))
        handle_notifs(plugin, %{deleted: deleted, inserted: inserted})
    end
  end

  defp handle_notifs(plugin, op) do
    {notifs, to_delete} =
      cond do
        op[:deleted] ->
          %{notifs: notifs, to_delete: to_delete} =
            plugin.notifs_for_delete(op.deleted, op[:inserted])

          {notifs, to_delete}

        op[:inserted] ->
          {plugin.notifs_for_insert(op.inserted), []}

        true ->
          {[], []}
      end

    if to_delete != [],
      do: Repo.delete_all(from(n in Notification, where: n.record_uri in ^to_delete))

    notifs
    |> Enum.reject(&thread_muted?/1)
    |> Enum.chunk_every(500)
    |> Enum.each(&Repo.insert_all(Notification, &1))

    :ok
  end

  # upstream isNotifBlockedByThreadMute: reply/quote/mention notifications
  # whose subject thread the recipient muted are not delivered
  defp thread_muted?(%{reason: reason} = n) when reason in ["reply", "quote", "mention"] do
    root = reply_root_of(n.record_uri) || n.reason_subject || n.record_uri
    Repo.exists?(from(m in ThreadMute, where: m.muted_by_did == ^n.did and m.root_uri == ^root))
  end

  defp thread_muted?(_), do: false

  defp reply_root_of(uri) do
    Repo.one(from(p in Aerox.AppView.Schema.Post, where: p.uri == ^uri, select: p.reply_root))
  end

  # ------------------------------------------------------------- actors

  @doc "Create the actor row on first sight."
  def ensure_actor(nil, _), do: :ok

  def ensure_actor(did, indexed_at) do
    Repo.insert_all(Actor, [%{did: did, indexed_at: indexed_at}],
      on_conflict: :nothing,
      conflict_target: :did
    )

    :ok
  end

  @doc "Record the last seen commit for a repo (upstream `setCommitLastSeen`)."
  def set_commit_last_seen(did, commit_cid, rev) do
    Repo.insert_all(ActorSync, [%{did: did, commit_cid: commit_cid, repo_rev: rev}],
      on_conflict: {:replace, [:commit_cid, :repo_rev]},
      conflict_target: :did
    )

    :ok
  end

  @doc "Upstream `indexHandle`: re-resolve the DID and store its verified handle (or nil)."
  def index_handle(did, indexed_at, handle \\ nil) do
    resolved =
      case Aerox.Identity.resolve_did(Aerox.AppView.Identity, did, force: true) do
        {:ok, doc} -> Aerox.ATProto.Identity.handle(doc)
        _ -> nil
      end

    handle = resolved || handle

    verified =
      cond do
        is_nil(handle) -> nil
        handle_resolves?(handle, did) -> handle
        true -> nil
      end

    ensure_actor(did, indexed_at)
    # DESIGN §15.1: a failed re-resolution never nulls a good handle
    if verified do
      Repo.update_all(from(a in Actor, where: a.did == ^did), set: [handle: verified])
    end

    :ok
  end

  defp handle_resolves?(handle, did) do
    case Aerox.Identity.resolve_handle(Aerox.AppView.Identity, handle, force: true) do
      {:ok, ^did} -> true
      _ -> false
    end
  end

  @doc "Upstream `updateActorStatus`: takedown or upstream status."
  def update_actor_status(did, opts) do
    ensure_actor(did, DateTime.utc_now())
    sets = Keyword.take(opts, [:upstream_status, :takedown_ref])
    Repo.update_all(from(a in Actor, where: a.did == ^did), set: sets)
    :ok
  end

  @doc "Upstream `deleteActor`/`unindexActor`: every record of the DID leaves the index."
  def unindex_actor(did) do
    uris = Repo.all(from(r in Record, where: r.did == ^did, select: r.uri))
    Enum.each(uris, &delete_record(&1, cascading: true))
    Repo.delete_all(from(n in Notification, where: n.did == ^did or n.author == ^did))
    Repo.delete_all(from(a in ActorSync, where: a.did == ^did))
    :ok
  end

  # ------------------------------------------------------------- helpers

  defp uri_did(uri) do
    case Syntax.parse_at_uri(uri) do
      {:ok, %{authority: did}} -> did
      _ -> nil
    end
  end

  defp uri_collection(uri) do
    case Syntax.parse_at_uri(uri) do
      {:ok, %{collection: c}} -> c
      _ -> nil
    end
  end

  # JSON form of a data-model record (CIDs as {"$link"}, bytes as {"$bytes"})
  defp json(record), do: Aerox.ATProto.Data.to_json(record)
end
