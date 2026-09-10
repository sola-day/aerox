defmodule Aerox.AppView.Hydration do
  @moduledoc """
  Batch loaders (DESIGN §15.3, upstream `hydration/*`): one round trip per
  entity type, never per item. `hydrate_*` functions take a state and a
  list of keys and return the state with the maps filled. Records are the
  stored JSON (data-model JSON form) so views can emit them verbatim.

  State maps: `actors` (did → actor+profile), `posts` (uri → post),
  `post_aggs`, `post_viewers`, `profile_viewers`, `profile_aggs`, `reposts`,
  `likes`, `follows`, `lists`, `list_viewers`, `feed_gens`, `labelers`,
  `threadgates`, `postgates`, `labels` (subject → labels), `post_blocks`
  (3p blocks between a post and its parent/root/embed authors),
  `bidirectional_blocks`, `known_followers`, `verifications`.
  """
  import Ecto.Query
  alias Aerox.ATProto.Syntax
  alias Aerox.AppView.{Config, Repo}
  alias Aerox.AppView.Schema, as: S

  @type state :: map

  @doc "A fresh state for a viewer (DID or nil) and the labelers whose labels apply."
  def new(opts \\ []) do
    %{
      ctx: %{
        viewer: Keyword.get(opts, :viewer),
        labelers: Keyword.get(opts, :labelers, Config.default_labelers()),
        include_takedowns: Keyword.get(opts, :include_takedowns, false)
      },
      actors: %{},
      posts: %{},
      post_aggs: %{},
      post_viewers: %{},
      profile_viewers: %{},
      profile_aggs: %{},
      reposts: %{},
      likes: %{},
      follows: %{},
      lists: %{},
      list_viewers: %{},
      list_aggs: %{},
      feed_gens: %{},
      feed_gen_aggs: %{},
      labelers: %{},
      threadgates: %{},
      postgates: %{},
      labels: %{},
      post_blocks: %{},
      bidirectional_blocks: %{},
      known_followers: %{},
      verifications: %{},
      thread_contexts: %{}
    }
  end

  # ------------------------------------------------------------- actors

  @doc "Actors with their profile record, status, labeler flag, chat declaration and verifications."
  def hydrate_actors(state, dids) do
    dids =
      dids
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(state.actors, &1))

    if dids == [], do: state, else: do_hydrate_actors(state, dids)
  end

  defp do_hydrate_actors(state, dids) do
    actors = Repo.all(from(a in S.Actor, where: a.did in ^dids)) |> Map.new(&{&1.did, &1})

    profile_uris = Enum.map(dids, &"at://#{&1}/app.bsky.actor.profile/self")
    chat_uris = Enum.map(dids, &"at://#{&1}/chat.bsky.actor.declaration/self")
    labeler_uris = Enum.map(dids, &"at://#{&1}/app.bsky.labeler.service/self")

    records =
      Repo.all(from(r in S.Record, where: r.uri in ^(profile_uris ++ chat_uris ++ labeler_uris)))
      |> Map.new(&{&1.uri, &1})

    statuses = Repo.all(from(s in S.ActorStatus, where: s.did in ^dids)) |> Map.new(&{&1.did, &1})

    verifications =
      Repo.all(from(v in S.Verification, where: v.subject in ^dids, order_by: [asc: v.sort_at]))
      |> Enum.group_by(& &1.subject)

    profiles =
      Repo.all(from(p in S.Profile, where: p.creator in ^dids)) |> Map.new(&{&1.creator, &1})

    new =
      for did <- dids, into: %{} do
        actor = actors[did]
        profile_record = records["at://#{did}/app.bsky.actor.profile/self"]
        chat = records["at://#{did}/chat.bsky.actor.declaration/self"]
        profile_row = profiles[did]

        {did,
         %{
           did: did,
           exists: not is_nil(actor),
           handle: actor && actor.handle,
           indexed_at: actor && actor.indexed_at,
           takedown_ref: actor && actor.takedown_ref,
           upstream_status: actor && actor.upstream_status,
           trusted_verifier: (actor && actor.trusted_verifier) || false,
           profile: profile_record && profile_record.json,
           profile_cid: profile_record && profile_record.cid,
           profile_takedown_ref: profile_record && profile_record.takedown_ref,
           profile_indexed_at: profile_row && profile_row.indexed_at,
           created_at: profile_row && profile_row.created_at,
           is_labeler: Map.has_key?(records, "at://#{did}/app.bsky.labeler.service/self"),
           allow_incoming_chats: chat && chat.json["allowIncoming"],
           status: statuses[did],
           verifications: verifications[did] || []
         }}
      end

    state = %{state | actors: Map.merge(state.actors, new)}
    # issuers of verifications are shown by handle/display name
    issuers = new |> Map.values() |> Enum.flat_map(& &1.verifications) |> Enum.map(& &1.creator)
    if issuers == [], do: state, else: hydrate_actors(state, issuers)
  end

  @doc "Follower/follows/posts counts."
  def hydrate_profile_aggs(state, dids) do
    dids = Enum.uniq(dids) -- Map.keys(state.profile_aggs)

    if dids == [] do
      state
    else
      aggs = Repo.all(from(a in S.ProfileAgg, where: a.did in ^dids)) |> Map.new(&{&1.did, &1})

      lists =
        Repo.all(
          from(l in S.List,
            where: l.creator in ^dids,
            group_by: l.creator,
            select: {l.creator, count(l.uri)}
          )
        )
        |> Map.new()

      feeds =
        Repo.all(
          from(f in S.FeedGenerator,
            where: f.creator in ^dids,
            group_by: f.creator,
            select: {f.creator, count(f.uri)}
          )
        )
        |> Map.new()

      packs =
        Repo.all(
          from(s in S.StarterPack,
            where: s.creator in ^dids,
            group_by: s.creator,
            select: {s.creator, count(s.uri)}
          )
        )
        |> Map.new()

      new =
        for did <- dids, into: %{} do
          a = aggs[did]

          {did,
           %{
             followers: (a && a.followers_count) || 0,
             follows: (a && a.follows_count) || 0,
             posts: (a && a.posts_count) || 0,
             lists: lists[did] || 0,
             feeds: feeds[did] || 0,
             starter_packs: packs[did] || 0
           }}
        end

      %{state | profile_aggs: Map.merge(state.profile_aggs, new)}
    end
  end

  @doc "The viewer's relationship to each actor (upstream getProfileViewerStatesNaive)."
  def hydrate_profile_viewers(%{ctx: %{viewer: nil}} = state, _dids), do: state

  def hydrate_profile_viewers(%{ctx: %{viewer: viewer}} = state, dids) do
    dids = Enum.uniq(dids) -- Map.keys(state.profile_viewers)

    if dids == [] do
      state
    else
      following =
        Repo.all(
          from(f in S.Follow,
            where: f.creator == ^viewer and f.subject_did in ^dids,
            select: {f.subject_did, f.uri}
          )
        )
        |> Map.new()

      followed_by =
        Repo.all(
          from(f in S.Follow,
            where: f.subject_did == ^viewer and f.creator in ^dids,
            select: {f.creator, f.uri}
          )
        )
        |> Map.new()

      blocking =
        Repo.all(
          from(b in S.ActorBlock,
            where: b.creator == ^viewer and b.subject_did in ^dids,
            select: {b.subject_did, b.uri}
          )
        )
        |> Map.new()

      blocked_by =
        Repo.all(
          from(b in S.ActorBlock,
            where: b.subject_did == ^viewer and b.creator in ^dids,
            select: {b.creator, b.uri}
          )
        )
        |> Map.new()

      muted =
        Repo.all(
          from(m in S.Mute,
            where: m.muted_by_did == ^viewer and m.subject_did in ^dids,
            select: m.subject_did
          )
        )
        |> MapSet.new()

      # list-based mutes and blocks: the viewer's muted/blocked lists containing the actor
      muted_by_list =
        Repo.all(
          from(i in S.ListItem,
            join: m in S.ListMute,
            on: m.list_uri == i.list_uri and m.muted_by_did == ^viewer,
            where: i.subject_did in ^dids,
            select: {i.subject_did, i.list_uri}
          )
        )
        |> Map.new()

      blocking_by_list =
        Repo.all(
          from(i in S.ListItem,
            join: b in S.ListBlock,
            on: b.subject_uri == i.list_uri and b.creator == ^viewer,
            where: i.subject_did in ^dids,
            select: {i.subject_did, i.list_uri}
          )
        )
        |> Map.new()

      blocked_by_list =
        Repo.all(
          from(i in S.ListItem,
            join: b in S.ListBlock,
            on: b.subject_uri == i.list_uri and b.creator in ^dids,
            where: i.subject_did == ^viewer,
            select: {b.creator, i.list_uri}
          )
        )
        |> Map.new()

      new =
        for did <- dids, into: %{} do
          {did,
           %{
             following: following[did],
             followed_by: followed_by[did],
             blocking: blocking[did],
             blocked_by: blocked_by[did],
             muted: MapSet.member?(muted, did),
             muted_by_list: muted_by_list[did],
             blocking_by_list: blocking_by_list[did],
             blocked_by_list: blocked_by_list[did]
           }}
        end

      state = %{state | profile_viewers: Map.merge(state.profile_viewers, new)}

      list_uris =
        new
        |> Map.values()
        |> Enum.flat_map(&[&1.muted_by_list, &1.blocking_by_list, &1.blocked_by_list])
        |> Enum.reject(&is_nil/1)

      hydrate_lists(state, list_uris)
    end
  end

  @doc "Known followers: followers of `dids` that the viewer follows (upstream getKnownFollowers)."
  def hydrate_known_followers(%{ctx: %{viewer: nil}} = state, _), do: state

  def hydrate_known_followers(%{ctx: %{viewer: viewer}} = state, dids) do
    dids = Enum.uniq(dids) -- Map.keys(state.known_followers)

    if dids == [] do
      state
    else
      rows =
        Repo.all(
          from(f in S.Follow,
            join: v in S.Follow,
            on: v.creator == ^viewer and v.subject_did == f.creator,
            where: f.subject_did in ^dids and f.creator != ^viewer,
            order_by: [desc: f.sort_at],
            select: {f.subject_did, f.creator}
          )
        )
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

      new =
        for did <- dids,
            into: %{},
            do: {did, %{count: length(rows[did] || []), followers: Enum.take(rows[did] || [], 5)}}

      state = %{state | known_followers: Map.merge(state.known_followers, new)}
      hydrate_actors(state, new |> Map.values() |> Enum.flat_map(& &1.followers))
    end
  end

  # -------------------------------------------------------------- posts

  @doc "Posts with their records, aggregates, gates, embedded records' targets (one level), authors and viewer state."
  def hydrate_posts(state, uris, opts \\ []) do
    depth = Keyword.get(opts, :depth, 0)

    uris =
      uris |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.reject(&Map.has_key?(state.posts, &1))

    if uris == [], do: state, else: do_hydrate_posts(state, uris, depth)
  end

  defp do_hydrate_posts(state, uris, depth) do
    rows =
      Repo.all(
        from(p in S.Post,
          join: r in S.Record,
          on: r.uri == p.uri,
          where: p.uri in ^uris,
          select: {p, r}
        )
      )

    new =
      for {p, r} <- rows, into: %{} do
        {p.uri,
         %{
           uri: p.uri,
           cid: p.cid,
           creator: p.creator,
           record: r.json,
           indexed_at: p.indexed_at,
           sort_at: p.sort_at,
           takedown_ref: r.takedown_ref,
           violates_thread_gate: p.violates_thread_gate == true,
           violates_embedding_rules: p.violates_embedding_rules == true,
           invalid_reply_root: p.invalid_reply_root == true,
           has_thread_gate: p.has_thread_gate == true,
           has_post_gate: p.has_post_gate == true
         }}
      end

    # posts absent from the index are remembered as missing so views can placeholder them
    missing = for uri <- uris, not Map.has_key?(new, uri), into: %{}, do: {uri, nil}
    state = %{state | posts: state.posts |> Map.merge(new) |> Map.merge(missing)}
    posts = Map.values(new)

    post_uris = Enum.map(posts, & &1.uri)
    creators = Enum.map(posts, & &1.creator)

    state =
      parallel(state, [
        &hydrate_post_aggs(&1, post_uris),
        &hydrate_post_viewers(&1, post_uris),
        &hydrate_actors(&1, creators),
        &hydrate_labels(&1, post_uris),
        &hydrate_gates(&1, posts)
      ])

    # replies: parent and root posts, for reply refs, thread boundaries and 3p blocks
    reply_uris =
      Enum.flat_map(
        posts,
        &[
          get_in(&1.record, ["reply", "parent", "uri"]),
          get_in(&1.record, ["reply", "root", "uri"])
        ]
      )

    # quoted records, one level deep (upstream depth < 2)
    embed_uris =
      if depth < 2, do: Enum.flat_map(posts, &embedded_uris(&1.record["embed"])), else: []

    of = fn uris, collection -> Enum.filter(uris, &(collection_of(&1) == collection)) end
    nested_posts = of.(reply_uris ++ embed_uris, "app.bsky.feed.post")
    feed_gens = of.(embed_uris, "app.bsky.feed.generator")
    lists = of.(embed_uris, "app.bsky.graph.list")
    labeler_dids = embed_uris |> of.("app.bsky.labeler.service") |> Enum.map(&did_of/1)

    state =
      parallel(state, [
        &hydrate_posts(&1, nested_posts, depth: depth + 1),
        &hydrate_feed_gens(&1, feed_gens),
        &hydrate_lists(&1, lists),
        &hydrate_labelers(&1, labeler_dids)
      ])

    hydrate_post_blocks(state, posts)
  end

  defp embedded_uris(%{"$type" => "app.bsky.embed.record", "record" => %{"uri" => uri}}),
    do: [uri]

  defp embedded_uris(%{
         "$type" => "app.bsky.embed.recordWithMedia",
         "record" => %{"record" => %{"uri" => uri}}
       }),
       do: [uri]

  defp embedded_uris(_), do: []

  def hydrate_post_aggs(state, uris) do
    uris = Enum.uniq(uris) -- Map.keys(state.post_aggs)

    if uris == [] do
      state
    else
      aggs = Repo.all(from(a in S.PostAgg, where: a.uri in ^uris)) |> Map.new(&{&1.uri, &1})

      new =
        for uri <- uris, into: %{} do
          a = aggs[uri]

          {uri,
           %{
             likes: (a && a.like_count) || 0,
             replies: (a && a.reply_count) || 0,
             reposts: (a && a.repost_count) || 0,
             quotes: (a && a.quote_count) || 0,
             bookmarks: (a && a.bookmark_count) || 0
           }}
        end

      %{state | post_aggs: Map.merge(state.post_aggs, new)}
    end
  end

  def hydrate_post_viewers(%{ctx: %{viewer: nil}} = state, _), do: state

  def hydrate_post_viewers(%{ctx: %{viewer: viewer}} = state, uris) do
    uris = Enum.uniq(uris) -- Map.keys(state.post_viewers)

    if uris == [] do
      state
    else
      likes =
        Repo.all(
          from(l in S.Like,
            where: l.creator == ^viewer and l.subject in ^uris,
            select: {l.subject, l.uri}
          )
        )
        |> Map.new()

      reposts =
        Repo.all(
          from(r in S.Repost,
            where: r.creator == ^viewer and r.subject in ^uris,
            select: {r.subject, r.uri}
          )
        )
        |> Map.new()

      bookmarks =
        Repo.all(
          from(b in S.Bookmark,
            where: b.creator == ^viewer and b.subject_uri in ^uris,
            select: b.subject_uri
          )
        )
        |> MapSet.new()

      roots =
        for uri <- uris,
            p = state.posts[uri],
            do: {uri, get_in(p.record, ["reply", "root", "uri"]) || uri}

      root_uris = roots |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

      muted_roots =
        Repo.all(
          from(m in S.ThreadMute,
            where: m.muted_by_did == ^viewer and m.root_uri in ^root_uris,
            select: m.root_uri
          )
        )
        |> MapSet.new()

      roots = Map.new(roots)

      new =
        for uri <- uris, into: %{} do
          {uri,
           %{
             like: likes[uri],
             repost: reposts[uri],
             bookmarked: MapSet.member?(bookmarks, uri),
             thread_muted: MapSet.member?(muted_roots, roots[uri] || uri)
           }}
        end

      %{state | post_viewers: Map.merge(state.post_viewers, new)}
    end
  end

  # thread gates of the roots and post gates of the posts themselves
  defp hydrate_gates(state, posts) do
    root_uris = Enum.map(posts, &(get_in(&1.record, ["reply", "root", "uri"]) || &1.uri))
    gate_uris = root_uris |> Enum.map(&gate_uri(&1, "app.bsky.feed.threadgate")) |> Enum.uniq()
    postgate_uris = posts |> Enum.map(&gate_uri(&1.uri, "app.bsky.feed.postgate")) |> Enum.uniq()

    wanted =
      (gate_uris -- Map.keys(state.threadgates)) ++ (postgate_uris -- Map.keys(state.postgates))

    if wanted == [] do
      state
    else
      found =
        Repo.all(from(r in S.Record, where: r.uri in ^wanted, select: {r.uri, r.json, r.cid}))
        |> Map.new(fn {u, j, c} -> {u, %{record: j, cid: c}} end)

      tg = for u <- gate_uris, into: %{}, do: {u, found[u]}
      pg = for u <- postgate_uris, into: %{}, do: {u, found[u]}

      %{
        state
        | threadgates: Map.merge(state.threadgates, tg),
          postgates: Map.merge(state.postgates, pg)
      }
    end
  end

  def gate_uri(post_uri, collection) do
    case Syntax.parse_at_uri(post_uri) do
      {:ok, %{authority: did, rkey: rkey}} -> "at://#{did}/#{collection}/#{rkey}"
      _ -> nil
    end
  end

  # Third-party blocks between a post's author and the authors of its parent, root and quoted post.
  defp hydrate_post_blocks(state, posts) do
    pairs =
      for p <- posts,
          {kind, other_uri} <- [
            {:parent, get_in(p.record, ["reply", "parent", "uri"])},
            {:root, get_in(p.record, ["reply", "root", "uri"])},
            {:embed, p.record["embed"] |> embedded_uris() |> List.first()}
          ],
          other_uri,
          other = did_of(other_uri),
          other && other != p.creator,
          do: {p.uri, kind, p.creator, other}

    if pairs == [] do
      state
    else
      state = hydrate_bidirectional_blocks(state, Enum.map(pairs, fn {_, _, a, b} -> {a, b} end))

      blocks =
        Enum.reduce(pairs, %{}, fn {uri, kind, a, b}, acc ->
          blocked = block_between?(state, a, b)
          Map.update(acc, uri, %{kind => blocked}, &Map.put(&1, kind, blocked))
        end)

      %{state | post_blocks: Map.merge(state.post_blocks, blocks)}
    end
  end

  @doc "Blocks (direct or by list) in either direction between pairs of DIDs."
  def hydrate_bidirectional_blocks(state, pairs) do
    dids = pairs |> Enum.flat_map(&Tuple.to_list/1) |> Enum.uniq()

    if dids == [] do
      state
    else
      direct =
        Repo.all(
          from(b in S.ActorBlock,
            where: b.creator in ^dids and b.subject_did in ^dids,
            select: {b.creator, b.subject_did}
          )
        )

      by_list =
        Repo.all(
          from(lb in S.ListBlock,
            join: i in S.ListItem,
            on: i.list_uri == lb.subject_uri,
            where: lb.creator in ^dids and i.subject_did in ^dids,
            select: {lb.creator, i.subject_did}
          )
        )

      set = MapSet.new(direct ++ by_list)

      new =
        Enum.reduce(pairs, state.bidirectional_blocks, fn {a, b}, acc ->
          blocked = MapSet.member?(set, {a, b}) or MapSet.member?(set, {b, a})

          acc
          |> Map.update(a, %{b => blocked}, &Map.put(&1, b, blocked))
          |> Map.update(b, %{a => blocked}, &Map.put(&1, a, blocked))
        end)

      %{state | bidirectional_blocks: new}
    end
  end

  def block_between?(state, a, b), do: get_in(state.bidirectional_blocks, [a, b]) == true

  # --------------------------------------------------- likes / reposts / follows

  for {name, schema} <- [reposts: S.Repost, likes: S.Like, follows: S.Follow] do
    def unquote(:"hydrate_#{name}")(state, uris) do
      uris = uris |> Enum.uniq() |> Enum.reject(&Map.has_key?(state[unquote(name)], &1))

      if uris == [] do
        state
      else
        rows =
          Repo.all(
            from(x in unquote(schema),
              join: r in S.Record,
              on: r.uri == x.uri,
              where: x.uri in ^uris,
              select: {x, r.json}
            )
          )

        new =
          for {x, json} <- rows,
              into: %{},
              do:
                {x.uri,
                 %{
                   uri: x.uri,
                   cid: x.cid,
                   creator: x.creator,
                   record: json,
                   indexed_at: x.indexed_at,
                   sort_at: x.sort_at
                 }}

        Map.put(state, unquote(name), Map.merge(state[unquote(name)], new))
      end
    end
  end

  # ------------------------------------------------------------- lists etc.

  def hydrate_lists(state, uris) do
    uris =
      uris |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.reject(&Map.has_key?(state.lists, &1))

    if uris == [] do
      state
    else
      rows =
        Repo.all(
          from(l in S.List,
            join: r in S.Record,
            on: r.uri == l.uri,
            where: l.uri in ^uris,
            select: {l, r.json}
          )
        )

      new = for {l, json} <- rows, into: %{}, do: {l.uri, %{row: l, record: json}}

      counts =
        Repo.all(
          from(i in S.ListItem,
            where: i.list_uri in ^uris,
            group_by: i.list_uri,
            select: {i.list_uri, count(i.uri)}
          )
        )
        |> Map.new()

      state = %{
        state
        | lists: Map.merge(state.lists, new),
          list_aggs: Map.merge(state.list_aggs, counts)
      }

      state = hydrate_actors(state, Enum.map(Map.values(new), & &1.row.creator))
      hydrate_list_viewers(state, Map.keys(new))
    end
  end

  def hydrate_list_viewers(%{ctx: %{viewer: nil}} = state, _), do: state

  def hydrate_list_viewers(%{ctx: %{viewer: viewer}} = state, uris) do
    uris = Enum.uniq(uris) -- Map.keys(state.list_viewers)

    if uris == [] do
      state
    else
      muted =
        Repo.all(
          from(m in S.ListMute,
            where: m.muted_by_did == ^viewer and m.list_uri in ^uris,
            select: m.list_uri
          )
        )
        |> MapSet.new()

      blocked =
        Repo.all(
          from(b in S.ListBlock,
            where: b.creator == ^viewer and b.subject_uri in ^uris,
            select: {b.subject_uri, b.uri}
          )
        )
        |> Map.new()

      in_list =
        Repo.all(
          from(i in S.ListItem,
            where: i.list_uri in ^uris and i.subject_did == ^viewer,
            select: {i.list_uri, i.uri}
          )
        )
        |> Map.new()

      new =
        for u <- uris,
            into: %{},
            do:
              {u,
               %{muted: MapSet.member?(muted, u), blocked: blocked[u], viewer_in_list: in_list[u]}}

      %{state | list_viewers: Map.merge(state.list_viewers, new)}
    end
  end

  def hydrate_feed_gens(state, uris) do
    uris =
      uris
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(state.feed_gens, &1))

    if uris == [] do
      state
    else
      rows =
        Repo.all(
          from(f in S.FeedGenerator,
            join: r in S.Record,
            on: r.uri == f.uri,
            where: f.uri in ^uris,
            select: {f, r.json}
          )
        )

      new = for {f, json} <- rows, into: %{}, do: {f.uri, %{row: f, record: json}}

      likes =
        Repo.all(
          from(l in S.Like,
            where: l.subject in ^uris,
            group_by: l.subject,
            select: {l.subject, count(l.uri)}
          )
        )
        |> Map.new()

      viewer_likes =
        case state.ctx.viewer do
          nil ->
            %{}

          v ->
            Repo.all(
              from(l in S.Like,
                where: l.creator == ^v and l.subject in ^uris,
                select: {l.subject, l.uri}
              )
            )
            |> Map.new()
        end

      aggs =
        for u <- uris, into: %{}, do: {u, %{likes: likes[u] || 0, viewer_like: viewer_likes[u]}}

      state = %{
        state
        | feed_gens: Map.merge(state.feed_gens, new),
          feed_gen_aggs: Map.merge(state.feed_gen_aggs, aggs)
      }

      hydrate_actors(state, Enum.map(Map.values(new), & &1.row.creator))
    end
  end

  def hydrate_labelers(state, dids) do
    dids =
      dids
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(state.labelers, &1))

    if dids == [] do
      state
    else
      uris = Enum.map(dids, &"at://#{&1}/app.bsky.labeler.service/self")

      rows =
        Repo.all(
          from(l in S.Labeler,
            join: r in S.Record,
            on: r.uri == l.uri,
            where: l.uri in ^uris,
            select: {l, r.json}
          )
        )

      new = for {l, json} <- rows, into: %{}, do: {l.creator, %{row: l, record: json}}

      likes =
        Repo.all(
          from(k in S.Like,
            where: k.subject in ^uris,
            group_by: k.subject,
            select: {k.subject, count(k.uri)}
          )
        )
        |> Map.new()

      new =
        Map.new(new, fn {did, v} ->
          {did, Map.put(v, :likes, likes["at://#{did}/app.bsky.labeler.service/self"] || 0)}
        end)

      state = %{state | labelers: Map.merge(state.labelers, new)}
      hydrate_actors(state, Map.keys(new))
    end
  end

  # ------------------------------------------------------------- labels

  @doc "Labels on subjects (URIs or DIDs) from the accepted labelers (DESIGN §15.6)."
  def hydrate_labels(state, subjects) do
    subjects =
      subjects
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.reject(&Map.has_key?(state.labels, &1))

    labelers = state.ctx.labelers

    cond do
      subjects == [] ->
        state

      labelers == [] ->
        %{state | labels: Map.merge(state.labels, Map.new(subjects, &{&1, []}))}

      true ->
        now = DateTime.utc_now()

        rows =
          Repo.all(
            from(l in S.Label,
              where:
                l.uri in ^subjects and l.src in ^labelers and l.neg == false and
                  (is_nil(l.exp) or l.exp > ^now)
            )
          )

        grouped = Enum.group_by(rows, & &1.uri)
        new = for s <- subjects, into: %{}, do: {s, grouped[s] || []}
        %{state | labels: Map.merge(state.labels, new)}
    end
  end

  # ------------------------------------------------------------- helpers

  def did_of(uri) do
    case uri && Syntax.parse_at_uri(uri) do
      {:ok, %{authority: did}} -> did
      _ -> nil
    end
  end

  def collection_of(uri) do
    case uri && Syntax.parse_at_uri(uri) do
      {:ok, %{collection: c}} -> c
      _ -> nil
    end
  end

  # -------------------------------------------------------- feed items

  @doc "Everything a list of feed items (`%{post: uri, repost: uri | nil}`) needs."
  def hydrate_feed_items(state, items) do
    state = hydrate_posts(state, Enum.map(items, & &1.post))
    state = hydrate_reposts(state, items |> Enum.map(& &1.repost) |> Enum.reject(&is_nil/1))
    reposters = state.reposts |> Map.values() |> Enum.map(& &1.creator)
    state = hydrate_actors(state, reposters)

    dids =
      (items |> Enum.map(&did_of(&1.post))) ++
        reposters ++
        (state.posts |> Map.values() |> Enum.reject(&is_nil/1) |> Enum.map(& &1.creator))

    parallel(state, [&hydrate_profile_viewers(&1, dids), &hydrate_labels(&1, dids)])
  end

  # ------------------------------------------------------------ parallel

  @doc false
  # Runs independent hydration stages concurrently (upstream's `Promise.all`
  # in the hydrator; bench/RESULTS.md: a timeline was 21 *sequential* round
  # trips). Every stage only adds entries under its own state keys, so the
  # results merge key by key; identical entries hydrated twice are identical.
  # Tasks inherit `$callers`, so the test sandbox and Logger metadata follow.
  def parallel(state, stages) do
    stages
    |> Task.async_stream(fn stage -> stage.(state) end,
      max_concurrency: length(stages),
      ordered: false,
      timeout: 30_000
    )
    |> Enum.reduce(state, fn {:ok, result}, acc -> merge_states(acc, result) end)
  end

  defp merge_states(acc, result) do
    Map.merge(acc, result, fn
      :ctx, ctx, _ -> ctx
      _key, a, b when is_map(a) and is_map(b) -> Map.merge(a, b)
      _key, _a, b -> b
    end)
  end

  @doc "Profiles: actors, aggregates, viewer state, labels, known followers."
  def hydrate_profiles(state, dids, opts \\ []) do
    detailed? = Keyword.get(opts, :detailed, false)
    label_subjects = dids ++ Enum.map(dids, &"at://#{&1}/app.bsky.actor.profile/self")

    parallel(
      state,
      [
        &hydrate_actors(&1, dids),
        &hydrate_profile_viewers(&1, dids),
        &hydrate_labels(&1, label_subjects)
      ] ++
        if(detailed?,
          do: [&hydrate_profile_aggs(&1, dids), &hydrate_known_followers(&1, dids)],
          else: []
        )
    )
  end
end
