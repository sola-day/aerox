defmodule Aerox.AppView.Notifications do
  @moduledoc """
  `app.bsky.notification.*` (DESIGN §15.5; upstream `listNotifications.ts`,
  `getUnreadCount.ts`, `updateSeen.ts` and the data-plane `notifs` route).
  Pages over `notification` by `(sort_at desc, id desc)` with a
  `<epoch ms>::<id>` cursor; `actor_state.last_seen_notifs` is the seen
  mark. Notifications from authors the viewer mutes or blocks (directly
  or by list) are excluded in SQL, so the count and the list agree.
  """
  import Ecto.Query
  alias Aerox.ATProto.Syntax
  alias Aerox.AppView.{Hydration, Repo, Views}
  alias Aerox.AppView.Schema, as: S

  @doc "listNotifications for the viewer in `state`: `notifications`, `cursor`, `seenAt`, `priority`."
  def list(limit, cursor, reasons, state) do
    viewer = state.ctx.viewer

    rows =
      if clearly_bad?(cursor) do
        []
      else
        from(n in S.Notification, as: :notif, where: n.did == ^viewer)
        |> reason_subject_exists()
        |> not_muted_or_blocked(viewer)
        |> maybe_reasons(reasons)
        |> paginate(cursor, limit)
        |> Repo.all()
      end

    last_seen =
      case Repo.get(S.ActorState, viewer) do
        %{last_seen_notifs: %DateTime{} = t} ->
          t

        _ ->
          # upstream: with no seen time, the first page treats the newest as the seen mark
          if is_nil(cursor) and rows != [], do: hd(rows).sort_at
      end

    state = hydrate(state, rows)

    notifications =
      rows
      |> Enum.reject(
        &(Views.viewer_block_exists?(&1.author, state) or
            Views.viewer_mute_exists?(&1.author, state))
      )
      |> Enum.map(&Views.notification(&1, last_seen, state))
      |> Enum.reject(&is_nil/1)

    %{
      "notifications" => notifications,
      "cursor" => next_cursor(rows, limit),
      "priority" => false,
      "seenAt" => last_seen && Syntax.format_datetime(last_seen)
    }
  end

  @doc "getUnreadCount: notifications newer than the seen mark (all, when nothing was ever seen)."
  def unread_count(viewer) do
    query =
      from(n in S.Notification,
        as: :notif,
        join: r in S.Record,
        on: r.uri == n.record_uri,
        join: a in S.Actor,
        on: a.did == n.author,
        where: n.did == ^viewer and is_nil(r.takedown_ref) and is_nil(a.takedown_ref),
        select: count(n.id)
      )
      |> reason_subject_exists()
      |> not_muted_or_blocked(viewer)

    query =
      case Repo.get(S.ActorState, viewer) do
        %{last_seen_notifs: %DateTime{} = t} -> where(query, [n], n.sort_at > ^t)
        _ -> query
      end

    Repo.one(query) || 0
  end

  @doc "updateSeen: upsert the seen mark."
  def update_seen(viewer, %DateTime{microsecond: {us, _}} = seen_at) do
    # clients send millisecond timestamps; the column is utc_datetime_usec
    seen_at = %{seen_at | microsecond: {us, 6}}

    Repo.insert!(
      %S.ActorState{did: viewer, last_seen_notifs: seen_at},
      on_conflict: [set: [last_seen_notifs: seen_at]],
      conflict_target: :did
    )

    :ok
  end

  # -------------------------------------------------------------- query bits

  # upstream: a notification whose reasonSubject was deleted is not shown
  defp reason_subject_exists(query) do
    where(
      query,
      [n],
      is_nil(n.reason_subject) or
        exists(from(r in S.Record, where: r.uri == parent_as(:notif).reason_subject))
    )
  end

  defp not_muted_or_blocked(query, viewer) do
    muted =
      from(m in S.Mute,
        where: m.muted_by_did == ^viewer and m.subject_did == parent_as(:notif).author
      )

    muted_by_list =
      from(i in S.ListItem,
        join: m in S.ListMute,
        on: m.list_uri == i.list_uri and m.muted_by_did == ^viewer,
        where: i.subject_did == parent_as(:notif).author
      )

    blocked =
      from(b in S.ActorBlock,
        where:
          (b.creator == ^viewer and b.subject_did == parent_as(:notif).author) or
            (b.subject_did == ^viewer and b.creator == parent_as(:notif).author)
      )

    blocked_by_list =
      from(i in S.ListItem,
        join: b in S.ListBlock,
        on: b.subject_uri == i.list_uri,
        where:
          (b.creator == ^viewer and i.subject_did == parent_as(:notif).author) or
            (i.subject_did == ^viewer and b.creator == parent_as(:notif).author)
      )

    query
    |> where([n], not exists(muted))
    |> where([n], not exists(muted_by_list))
    |> where([n], not exists(blocked))
    |> where([n], not exists(blocked_by_list))
  end

  defp maybe_reasons(query, reasons) when is_list(reasons) and reasons != [],
    do: where(query, [n], n.reason in ^reasons)

  defp maybe_reasons(query, _), do: query

  # `sort_at` has microseconds, the cursor milliseconds: page at the millisecond (see Cursor.paginate)
  defp paginate(query, cursor, limit) do
    query =
      case parse(cursor) do
        nil ->
          query

        {dt, id} ->
          where(
            query,
            [n],
            fragment("date_trunc('milliseconds', ?)", n.sort_at) < ^dt or
              (fragment("date_trunc('milliseconds', ?)", n.sort_at) == ^dt and n.id < ^id)
          )
      end

    query
    |> order_by([n], desc: fragment("date_trunc('milliseconds', ?)", n.sort_at), desc: n.id)
    |> limit(^limit)
  end

  defp parse(nil), do: nil

  defp parse(cursor) do
    with [ms, id] <- String.split(cursor, "::", parts: 2),
         {ms, ""} <- Integer.parse(ms),
         {id, ""} <- Integer.parse(id),
         {:ok, dt} <- DateTime.from_unix(ms, :millisecond) do
      {%{dt | microsecond: {elem(dt.microsecond, 0), 6}}, id}
    else
      _ -> nil
    end
  end

  defp clearly_bad?(nil), do: false
  defp clearly_bad?(cursor), do: is_nil(parse(cursor))

  defp next_cursor(rows, limit) do
    if length(rows) >= limit and rows != [] do
      last = List.last(rows)
      "#{DateTime.to_unix(last.sort_at, :millisecond)}::#{last.id}"
    end
  end

  # ------------------------------------------------------------- hydration

  # upstream hydrateNotifications: the records by collection, then the authors as profiles
  defp hydrate(state, rows) do
    by_collection = Enum.group_by(rows, &Hydration.collection_of(&1.record_uri), & &1.record_uri)

    state
    |> Hydration.hydrate_posts(by_collection["app.bsky.feed.post"] || [])
    |> Hydration.hydrate_likes(by_collection["app.bsky.feed.like"] || [])
    |> Hydration.hydrate_reposts(by_collection["app.bsky.feed.repost"] || [])
    |> Hydration.hydrate_follows(by_collection["app.bsky.graph.follow"] || [])
    |> hydrate_verifications(by_collection["app.bsky.graph.verification"] || [])
    |> Hydration.hydrate_profiles(Enum.map(rows, & &1.author))
    |> Hydration.hydrate_labels(Enum.map(rows, & &1.record_uri))
  end

  # Views.notification reads `state.verifications[uri]` (cid + record); Hydration has no loader for it
  defp hydrate_verifications(state, []), do: state

  defp hydrate_verifications(state, uris) do
    found =
      Repo.all(from(r in S.Record, where: r.uri in ^uris, select: {r.uri, r.cid, r.json}))
      |> Map.new(fn {uri, cid, json} -> {uri, %{cid: cid, record: json}} end)

    %{state | verifications: Map.merge(state.verifications, found)}
  end
end
