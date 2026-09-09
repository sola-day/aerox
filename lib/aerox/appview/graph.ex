defmodule Aerox.AppView.Graph do
  @moduledoc """
  The `app.bsky.graph.*` read path and the mute writes (DESIGN §15.3,
  §15.7; upstream `api/app/bsky/graph/*` and the data-plane's `follows`,
  `blocks`, `mutes`, `lists`, `relationships`, `starter-packs` routes).
  Skeletons are keyset-paginated with `Aerox.AppView.Cursor`; blocked
  pairs are hidden as upstream's `noBlocks` rules do.
  """
  import Ecto.Query
  alias Aerox.ATProto.Syntax
  require Aerox.AppView.Cursor
  alias Aerox.AppView.{Actors, Cursor, Hydration, Repo, Views}
  alias Aerox.AppView.Schema, as: S

  # --------------------------------------------------- follows / followers

  @doc "getFollows: the subject's profile and the profiles it follows (upstream getFollows.ts)."
  def follows(actor, limit, cursor, state), do: follow_page(:follows, actor, limit, cursor, state)

  @doc "getFollowers: the subject's profile and the profiles following it (upstream getFollowers.ts)."
  def followers(actor, limit, cursor, state),
    do: follow_page(:followers, actor, limit, cursor, state)

  defp follow_page(kind, actor, limit, cursor, state) do
    with did when is_binary(did) <- Actors.resolve_did(actor) || {:error, :not_found} do
      rows =
        if Cursor.clearly_bad?(cursor) do
          []
        else
          case kind do
            :follows -> from(f in S.Follow, where: f.creator == ^did)
            :followers -> from(f in S.Follow, where: f.subject_did == ^did)
          end
          |> Cursor.paginate(cursor, limit)
          |> Repo.all()
        end

      others = Enum.map(rows, &if(kind == :follows, do: &1.subject_did, else: &1.creator))

      state =
        state
        |> Hydration.hydrate_profiles([did | others])
        |> Hydration.hydrate_bidirectional_blocks(Enum.map(others, &{did, &1}))

      subject = if Actors.exists?(did, state), do: Views.profile(did, state)

      cond do
        is_nil(subject) or Views.actor_no_hosted?(did, state) ->
          {:error, :not_found}

        true ->
          views =
            others
            |> Enum.reject(&Hydration.block_between?(state, did, &1))
            |> Enum.reject(&(state.ctx.viewer && Views.viewer_block_exists?(&1, state)))
            |> Enum.reject(&Views.actor_no_hosted?(&1, state))
            |> Enum.map(&Views.profile(&1, state))
            |> Enum.reject(&is_nil/1)

          key = if kind == :follows, do: "follows", else: "followers"
          {:ok, %{"subject" => subject, key => views, "cursor" => Cursor.next(rows, limit)}}
      end
    end
  end

  @doc "getKnownFollowers: followers of the subject that the viewer follows (viewer required)."
  def known_followers(actor, limit, state) do
    viewer = state.ctx.viewer

    with did when is_binary(did) <- Actors.resolve_did(actor) || {:error, :not_found} do
      dids =
        Repo.all(
          from(f in S.Follow,
            join: v in S.Follow,
            on: v.creator == ^viewer and v.subject_did == f.creator,
            where: f.subject_did == ^did and f.creator != ^viewer,
            order_by: [desc: f.sort_at, desc: f.cid],
            limit: ^limit,
            select: f.creator
          )
        )

      state = Hydration.hydrate_profiles(state, [did | dids])

      if Actors.exists?(did, state) do
        followers =
          dids
          |> Enum.reject(&Views.viewer_block_exists?(&1, state))
          |> Enum.map(&Views.profile(&1, state))
          |> Enum.reject(&is_nil/1)

        {:ok, %{"subject" => Views.profile(did, state), "followers" => followers}}
      else
        {:error, :not_found}
      end
    end
  end

  # ------------------------------------------------------ blocks / mutes

  @doc "getBlocks: the viewer's direct blocks, newest first."
  def blocks(limit, cursor, state) do
    viewer = state.ctx.viewer

    rows =
      if Cursor.clearly_bad?(cursor),
        do: [],
        else:
          from(b in S.ActorBlock, where: b.creator == ^viewer)
          |> Cursor.paginate(cursor, limit)
          |> Repo.all()

    {views, _} = Actors.profiles(Enum.map(rows, & &1.subject_did), state, no_blocks: false)
    %{"blocks" => views, "cursor" => Cursor.next(rows, limit)}
  end

  @doc "getMutes: the viewer's direct mutes (upstream CreatedAtDidKeyset: `<ms>::<did>`)."
  def mutes(limit, cursor, state) do
    viewer = state.ctx.viewer
    query = from(m in S.Mute, where: m.muted_by_did == ^viewer)

    query =
      case Cursor.parse(cursor) do
        nil ->
          query

        {dt, did} ->
          where(
            query,
            [m],
            fragment("date_trunc('milliseconds', ?)", m.created_at) < ^dt or
              (fragment("date_trunc('milliseconds', ?)", m.created_at) == ^dt and
                 m.subject_did < ^did)
          )
      end

    rows =
      if Cursor.clearly_bad?(cursor),
        do: [],
        else:
          query
          |> order_by([m],
            desc: fragment("date_trunc('milliseconds', ?)", m.created_at),
            desc: m.subject_did
          )
          |> limit(^limit)
          |> Repo.all()

    {views, _} = Actors.profiles(Enum.map(rows, & &1.subject_did), state, no_blocks: false)

    next =
      if length(rows) >= limit and rows != [],
        do: Cursor.pack(List.last(rows).created_at, List.last(rows).subject_did)

    %{"mutes" => views, "cursor" => next}
  end

  # ----------------------------------------------------------------- lists

  @doc "getList: the list view and a page of its members as `#listItemView`s (upstream getList.ts)."
  def list(uri, limit, cursor, state) do
    rows =
      if Cursor.clearly_bad?(cursor),
        do: [],
        else:
          from(i in S.ListItem, where: i.list_uri == ^uri)
          |> Cursor.paginate(cursor, limit)
          |> Repo.all()

    members = Enum.map(rows, & &1.subject_did)
    creator = Hydration.did_of(uri)

    state =
      state
      |> Hydration.hydrate_lists([uri])
      |> Hydration.hydrate_profiles(members)

    case Views.list(uri, state) do
      nil ->
        {:error, :not_found}

      list ->
        # members blocked by (or blocking) the curator are hidden, except on
        # mod lists and for the curator's own view
        state =
          if state.ctx.viewer == creator or list["purpose"] == "app.bsky.graph.defs#modlist",
            do: state,
            else: Hydration.hydrate_bidirectional_blocks(state, Enum.map(members, &{creator, &1}))

        items =
          for row <- rows,
              not Hydration.block_between?(state, creator, row.subject_did),
              Actors.exists?(row.subject_did, state),
              subject = Views.profile(row.subject_did, state),
              do: %{"uri" => row.uri, "subject" => subject}

        {:ok, %{"list" => list, "items" => items, "cursor" => Cursor.next(rows, limit)}}
    end
  end

  @doc "getLists: the lists an actor created."
  def lists(actor, limit, cursor, state) do
    with did when is_binary(did) <- Actors.resolve_did(actor) || {:error, :not_found} do
      rows =
        if Cursor.clearly_bad?(cursor),
          do: [],
          else:
            from(l in S.List, where: l.creator == ^did)
            |> Cursor.paginate(cursor, limit)
            |> Repo.all()

      {:ok, list_views(rows, Cursor.next(rows, limit), state)}
    end
  end

  @doc "getListMutes: the lists the viewer mutes (cursor `<ms>::<list uri>` over created_at)."
  def list_mutes(limit, cursor, state) do
    viewer = state.ctx.viewer
    query = from(m in S.ListMute, where: m.muted_by_did == ^viewer)

    query =
      case Cursor.parse(cursor) do
        nil ->
          query

        {dt, u} ->
          where(
            query,
            [m],
            fragment("date_trunc('milliseconds', ?)", m.created_at) < ^dt or
              (fragment("date_trunc('milliseconds', ?)", m.created_at) == ^dt and
                 m.list_uri < ^u)
          )
      end

    rows =
      if Cursor.clearly_bad?(cursor),
        do: [],
        else:
          query
          |> order_by([m],
            desc: fragment("date_trunc('milliseconds', ?)", m.created_at),
            desc: m.list_uri
          )
          |> limit(^limit)
          |> Repo.all()

    next =
      if length(rows) >= limit and rows != [],
        do: Cursor.pack(List.last(rows).created_at, List.last(rows).list_uri)

    state = Hydration.hydrate_lists(state, Enum.map(rows, & &1.list_uri))
    lists = rows |> Enum.map(&Views.list(&1.list_uri, state)) |> Enum.reject(&is_nil/1)
    %{"lists" => lists, "cursor" => next}
  end

  @doc "getListBlocks: the lists the viewer blocks through `app.bsky.graph.listblock` records."
  def list_blocks(limit, cursor, state) do
    viewer = state.ctx.viewer

    rows =
      if Cursor.clearly_bad?(cursor),
        do: [],
        else:
          from(b in S.ListBlock, where: b.creator == ^viewer)
          |> Cursor.paginate(cursor, limit)
          |> Repo.all()

    state = Hydration.hydrate_lists(state, Enum.map(rows, & &1.subject_uri))
    lists = rows |> Enum.map(&Views.list(&1.subject_uri, state)) |> Enum.reject(&is_nil/1)
    %{"lists" => lists, "cursor" => Cursor.next(rows, limit)}
  end

  defp list_views(rows, cursor, state) do
    uris = Enum.map(rows, & &1.uri)
    state = Hydration.hydrate_lists(state, uris)

    %{
      "lists" => uris |> Enum.map(&Views.list(&1, state)) |> Enum.reject(&is_nil/1),
      "cursor" => cursor
    }
  end

  # --------------------------------------------------------- relationships

  @doc "getRelationships: `actor`'s relationship to each of `others` (upstream getRelationships.ts)."
  def relationships(actor, others) do
    actor_did = Actors.resolve_did(actor)
    resolved = Enum.map(others, &{&1, Actors.resolve_did(&1)})
    dids = for {_, did} <- resolved, did, do: did

    viewers =
      if actor_did && dids != [] do
        Hydration.new(viewer: actor_did)
        |> Hydration.hydrate_profile_viewers(dids)
        |> Map.fetch!(:profile_viewers)
      else
        %{}
      end

    relationships =
      for {other, did} <- resolved do
        case did && viewers[did] do
          nil ->
            %{
              "$type" => "app.bsky.graph.defs#notFoundActor",
              "actor" => other,
              "notFound" => true
            }

          v ->
            %{
              "$type" => "app.bsky.graph.defs#relationship",
              "did" => did,
              "following" => v.following,
              "followedBy" => v.followed_by,
              "blocking" => v.blocking,
              "blockedBy" => v.blocked_by,
              "blockingByList" => v.blocking_by_list,
              "blockedByList" => v.blocked_by_list
            }
            |> compact()
        end
      end

    compact(%{"actor" => actor_did, "relationships" => relationships})
  end

  # ---------------------------------------------------------- starter packs

  @doc "getStarterPack: the full `#starterPackView` (the URI may name the creator by handle, as upstream resolveUri)."
  def starter_pack(uri, state) do
    with {:ok, uri} <- resolve_uri(uri),
         state = hydrate_starter_packs(state, [uri]),
         %{} = basic <- starter_pack_basic(uri, state) || {:error, :not_found} do
      record = state.starter_packs[uri].record
      list_uri = record["list"]
      feed_uris = for %{"uri" => u} <- record["feeds"] || [], is_binary(u), do: u

      sample_rows =
        if is_binary(list_uri),
          do:
            Repo.all(
              from(i in S.ListItem,
                where: i.list_uri == ^list_uri,
                order_by: [asc: i.sort_at, asc: i.cid],
                limit: 12
              )
            ),
          else: []

      state =
        state
        |> Hydration.hydrate_lists(List.wrap(list_uri))
        |> Hydration.hydrate_feed_gens(feed_uris)
        |> Hydration.hydrate_profiles(Enum.map(sample_rows, & &1.subject_did))

      sample =
        for row <- sample_rows,
            Actors.exists?(row.subject_did, state),
            subject = Views.profile(row.subject_did, state),
            do: %{"uri" => row.uri, "subject" => subject}

      view =
        basic
        |> Map.merge(%{
          "feeds" =>
            feed_uris |> Enum.map(&Views.feed_generator(&1, state)) |> Enum.reject(&is_nil/1),
          "list" => list_uri && Views.list_basic(list_uri, state),
          "listItemsSample" => sample
        })
        |> compact()

      {:ok, view}
    end
  end

  @doc "getStarterPacks: basic views of the given URIs (unknown ones omitted)."
  def starter_packs(uris, state) do
    state = hydrate_starter_packs(state, uris)
    uris |> Enum.map(&starter_pack_basic(&1, state)) |> Enum.reject(&is_nil/1)
  end

  @doc "getActorStarterPacks: basic views of the packs an actor created."
  def actor_starter_packs(actor, limit, cursor, state) do
    with did when is_binary(did) <- Actors.resolve_did(actor) || {:error, :not_found} do
      rows =
        if Cursor.clearly_bad?(cursor),
          do: [],
          else:
            from(s in S.StarterPack, where: s.creator == ^did)
            |> Cursor.paginate(cursor, limit)
            |> Repo.all()

      views = starter_packs(Enum.map(rows, & &1.uri), state)
      {:ok, %{"starterPacks" => views, "cursor" => Cursor.next(rows, limit)}}
    end
  end

  # Upstream hydrateStarterPacksBasic: rows + records, creators, join counts, labels.
  # Kept under `state.starter_packs` / `state.starter_pack_aggs` (Hydration has no loader yet).
  defp hydrate_starter_packs(state, uris) do
    uris = uris |> Enum.uniq() |> Enum.reject(&Map.has_key?(state[:starter_packs] || %{}, &1))

    if uris == [] do
      state
    else
      rows =
        Repo.all(
          from(s in S.StarterPack,
            join: r in S.Record,
            on: r.uri == s.uri,
            where: s.uri in ^uris,
            select: {s, r.json}
          )
        )

      found = for {s, json} <- rows, into: %{}, do: {s.uri, %{row: s, record: json}}
      week_ago = DateTime.add(DateTime.utc_now(), -7, :day)

      all_time =
        Repo.all(
          from(p in S.Profile,
            where: p.joined_via_starter_pack_uri in ^uris,
            group_by: p.joined_via_starter_pack_uri,
            select: {p.joined_via_starter_pack_uri, count(p.uri)}
          )
        )
        |> Map.new()

      week =
        Repo.all(
          from(p in S.Profile,
            where: p.joined_via_starter_pack_uri in ^uris and p.indexed_at > ^week_ago,
            group_by: p.joined_via_starter_pack_uri,
            select: {p.joined_via_starter_pack_uri, count(p.uri)}
          )
        )
        |> Map.new()

      aggs = for u <- uris, into: %{}, do: {u, %{all_time: all_time[u] || 0, week: week[u] || 0}}

      state
      |> Map.update(:starter_packs, found, &Map.merge(&1, found))
      |> Map.update(:starter_pack_aggs, aggs, &Map.merge(&1, aggs))
      |> Hydration.hydrate_profiles(Enum.map(Map.values(found), & &1.row.creator))
      |> Hydration.hydrate_labels(Map.keys(found))
    end
  end

  # upstream views.starterPackBasic
  defp starter_pack_basic(uri, state) do
    with %{row: row, record: record} <- get_in(state, [:starter_packs, uri]),
         true <- Actors.exists?(row.creator, state),
         %{} = creator <- Views.profile_basic(row.creator, state) do
      aggs = get_in(state, [:starter_pack_aggs, uri]) || %{all_time: 0, week: 0}

      %{
        "uri" => uri,
        "cid" => row.cid,
        "record" => record,
        "creator" => creator,
        "joinedAllTimeCount" => aggs.all_time,
        "joinedWeekCount" => aggs.week,
        "labels" => Enum.map(state.labels[uri] || [], &label_view/1),
        "indexedAt" => Syntax.format_datetime(row.indexed_at)
      }
    else
      _ -> nil
    end
  end

  defp label_view(%{src: src, uri: uri, cid: cid, val: val, cts: cts, exp: exp}) do
    compact(%{
      "src" => src,
      "uri" => uri,
      "cid" => cid,
      "val" => val,
      "cts" => cts && Syntax.format_datetime(cts),
      "exp" => exp && Syntax.format_datetime(exp)
    })
  end

  # upstream hydrator.resolveUri: `at://<handle>/...` → `at://<did>/...`
  defp resolve_uri(uri) do
    case Syntax.parse_at_uri(uri) do
      {:ok, %{authority: "did:" <> _}} ->
        {:ok, uri}

      {:ok, %{authority: handle, collection: c, rkey: r}} ->
        case Actors.resolve_did(handle) do
          nil -> {:error, :not_found}
          did -> {:ok, "at://#{did}/#{c}/#{r}"}
        end

      _ ->
        {:error, :not_found}
    end
  end

  # ------------------------------------------------------------ mutes (writes)

  @doc "muteActor (DESIGN §15.7): `:not_found` for an unknown actor, `:self` for the viewer themselves."
  def mute_actor(viewer, actor) do
    case Actors.resolve_did(actor) do
      nil ->
        {:error, :not_found}

      ^viewer ->
        {:error, :self}

      did ->
        Repo.insert!(
          %S.Mute{muted_by_did: viewer, subject_did: did, created_at: DateTime.utc_now()},
          on_conflict: :nothing
        )

        :ok
    end
  end

  def unmute_actor(viewer, actor) do
    case Actors.resolve_did(actor) do
      nil ->
        {:error, :not_found}

      ^viewer ->
        {:error, :self}

      did ->
        Repo.delete_all(
          from(m in S.Mute, where: m.muted_by_did == ^viewer and m.subject_did == ^did)
        )

        :ok
    end
  end

  def mute_list(viewer, list_uri) do
    with :ok <- check_list_uri(list_uri) do
      Repo.insert!(
        %S.ListMute{muted_by_did: viewer, list_uri: list_uri, created_at: DateTime.utc_now()},
        on_conflict: :nothing
      )

      :ok
    end
  end

  def unmute_list(viewer, list_uri) do
    with :ok <- check_list_uri(list_uri) do
      Repo.delete_all(
        from(m in S.ListMute, where: m.muted_by_did == ^viewer and m.list_uri == ^list_uri)
      )

      :ok
    end
  end

  def mute_thread(viewer, root) do
    with :ok <- check_post_uri(root) do
      Repo.insert!(
        %S.ThreadMute{muted_by_did: viewer, root_uri: root, created_at: DateTime.utc_now()},
        on_conflict: :nothing
      )

      :ok
    end
  end

  def unmute_thread(viewer, root) do
    with :ok <- check_post_uri(root) do
      Repo.delete_all(
        from(m in S.ThreadMute, where: m.muted_by_did == ^viewer and m.root_uri == ^root)
      )

      :ok
    end
  end

  defp check_list_uri(uri) do
    case Syntax.parse_at_uri(uri) do
      {:ok, %{collection: "app.bsky.graph.list", rkey: r}} when is_binary(r) and r != "" -> :ok
      _ -> {:error, :invalid_list}
    end
  end

  defp check_post_uri(uri) do
    case Syntax.parse_at_uri(uri) do
      {:ok, %{collection: "app.bsky.feed.post", rkey: r}} when is_binary(r) and r != "" -> :ok
      _ -> {:error, :invalid_post}
    end
  end

  defp compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
end
