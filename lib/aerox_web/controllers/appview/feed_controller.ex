defmodule AeroxWeb.AppView.FeedController do
  @moduledoc """
  `app.bsky.feed.*` (DESIGN §15.3–15.4, §15.8; upstream `api/app/bsky/feed/*.ts`):
  every action is skeleton (`Aerox.AppView.Feeds`) → hydration
  (`Aerox.AppView.Hydration`) → block/mute rules → presentation
  (`Aerox.AppView.Views`). Labelers come from `atproto-accept-labelers` and are
  echoed in `atproto-content-labelers`, as upstream.
  """
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  alias Aerox.ATProto.Syntax
  alias Aerox.AppView.{Actors, Config, Feeds, Hydration, Views}
  alias AeroxWeb.XRPC.Error

  # ------------------------------------------------------------- timeline

  def get_timeline(conn, _) do
    viewer = viewer!(conn)
    params = params!(conn, "app.bsky.feed.getTimeline")
    labelers = labelers(conn)

    %{items: items, cursor: cursor} = Feeds.timeline(viewer, params["limit"], params["cursor"])

    state =
      Hydration.new(viewer: viewer, labelers: labelers.dids)
      |> Hydration.hydrate_feed_items(items)
      |> Feeds.finish_posts()

    items = Enum.filter(items, &no_blocks_or_mutes?(&1, state))

    respond_feed(conn, labelers, items, cursor, state)
  end

  # ----------------------------------------------------------- author feed

  def get_author_feed(conn, _) do
    viewer = conn.assigns.viewer
    params = params!(conn, "app.bsky.feed.getAuthorFeed")
    labelers = labelers(conn)
    did = actor!(params["actor"])

    filter = params["filter"] || "posts_with_replies"

    %{items: items, cursor: cursor} =
      Feeds.author_feed(
        did,
        filter,
        params["limit"],
        params["cursor"],
        params["includePins"] || false
      )

    state =
      Hydration.new(viewer: viewer, labelers: labelers.dids)
      |> Hydration.hydrate_actors([did])
      |> Hydration.hydrate_profile_viewers([did])
      |> Hydration.hydrate_feed_items(items)
      |> Feeds.finish_posts()

    unless get_in(state.actors, [did, :exists]),
      do: raise(Error.invalid_request("Profile not found"))

    # upstream noBlocksOrMutedReposts
    case state.profile_viewers[did] do
      %{blocking: b, blocking_by_list: bl} when b != nil or bl != nil ->
        raise Error.invalid_request("Requester has blocked actor: #{did}", "BlockedActor")

      %{blocked_by: b, blocked_by_list: bl} when b != nil or bl != nil ->
        raise Error.invalid_request("Requester is blocked by actor: #{did}", "BlockedByActor")

      _ ->
        :ok
    end

    items =
      Enum.filter(items, fn item ->
        bam = Views.feed_item_blocks_and_mutes(item, state)

        not bam.author_blocked and not bam.originator_blocked and
          (not bam.author_muted or bam.originator_muted)
      end)

    items =
      if filter == "posts_and_author_threads",
        do: Feeds.self_thread_filter(items, state),
        else: items

    respond_feed(conn, labelers, items, cursor, state)
  end

  # ---------------------------------------------------------------- thread

  def get_post_thread(conn, _) do
    viewer = conn.assigns.viewer
    params = params!(conn, "app.bsky.feed.getPostThread")
    labelers = labelers(conn)
    anchor = Actors.resolve_uri(params["uri"])
    depth = params["depth"] || 6
    height = params["parentHeight"] || 80

    uris = Feeds.thread(anchor, height, depth)

    state =
      Hydration.new(viewer: viewer, labelers: labelers.dids)
      |> Hydration.hydrate_posts([anchor | uris])
      |> Feeds.finish_posts()
      |> Feeds.hydrate_thread_contexts([anchor | uris])

    thread = Views.thread(anchor, uris, state, height, depth)

    if thread["$type"] == "app.bsky.feed.defs#notFoundPost",
      do: raise(Error.invalid_request("Post not found: #{anchor}", "NotFound"))

    root_uri =
      (state.posts[anchor] && get_in(state.posts[anchor].record, ["reply", "root", "uri"])) ||
        anchor

    threadgate = Views.threadgate(Hydration.gate_uri(root_uri, "app.bsky.feed.threadgate"), state)

    respond_labeled(conn, labelers, compact(%{"thread" => thread, "threadgate" => threadgate}))
  end

  # ----------------------------------------------------------------- posts

  def get_posts(conn, _) do
    viewer = conn.assigns.viewer
    params = params!(with_repeated(conn, ["uris"]), "app.bsky.feed.getPosts")
    labelers = labelers(conn)
    uris = Enum.uniq(params["uris"] || [])

    state =
      Hydration.new(viewer: viewer, labelers: labelers.dids)
      |> Hydration.hydrate_posts(uris)
      |> Feeds.finish_posts()

    posts =
      uris
      |> Enum.reject(&Views.viewer_block_exists?(Hydration.did_of(&1), state))
      |> Enum.map(&Views.post(&1, state))
      |> Enum.reject(&is_nil/1)

    respond_labeled(conn, labelers, %{"posts" => posts})
  end

  def get_likes(conn, _) do
    viewer = conn.assigns.viewer
    params = params!(conn, "app.bsky.feed.getLikes")
    labelers = labelers(conn)
    uri = params["uri"]

    if String.starts_with?(params["cursor"] || "", "did:"),
      do: raise(Error.invalid_request("Cursor appear to be out of date, please try reloading."))

    %{uris: like_uris, cursor: cursor} = Feeds.likes_of(uri, params["limit"], params["cursor"])
    author = Hydration.did_of(uri)

    state =
      Hydration.new(viewer: viewer, labelers: labelers.dids)
      |> Hydration.hydrate_likes(like_uris)

    likers = like_uris |> Enum.map(&Hydration.did_of/1) |> Enum.uniq()

    state =
      state
      |> Hydration.hydrate_profiles(likers)
      |> Hydration.hydrate_bidirectional_blocks(Enum.map(likers, &{author, &1}))

    likes =
      for like_uri <- like_uris,
          like = state.likes[like_uri],
          liker = like.creator,
          not Hydration.block_between?(state, author, liker),
          not Views.viewer_block_exists?(liker, state),
          actor = Views.profile(liker, state) do
        %{
          "actor" => actor,
          "createdAt" => Feeds.normalize_datetime(like.record["createdAt"], like.sort_at),
          "indexedAt" => Syntax.format_datetime(like.sort_at)
        }
      end

    respond_labeled(
      conn,
      labelers,
      compact(%{"uri" => uri, "cid" => params["cid"], "likes" => likes, "cursor" => cursor})
    )
  end

  def get_reposted_by(conn, _) do
    viewer = conn.assigns.viewer
    params = params!(conn, "app.bsky.feed.getRepostedBy")
    labelers = labelers(conn)
    uri = params["uri"]

    %{uris: repost_uris, cursor: cursor} =
      Feeds.reposts_of(uri, params["limit"], params["cursor"])

    reposters = repost_uris |> Enum.map(&Hydration.did_of/1) |> Enum.uniq()

    state =
      Hydration.new(viewer: viewer, labelers: labelers.dids)
      |> Hydration.hydrate_reposts(repost_uris)
      |> Hydration.hydrate_profiles(reposters)

    reposted_by =
      for repost_uri <- repost_uris,
          repost = state.reposts[repost_uri],
          not Views.viewer_block_exists?(repost.creator, state),
          profile = Views.profile(repost.creator, state),
          do: profile

    respond_labeled(
      conn,
      labelers,
      compact(%{
        "uri" => uri,
        "cid" => params["cid"],
        "repostedBy" => reposted_by,
        "cursor" => cursor
      })
    )
  end

  def get_quotes(conn, _) do
    viewer = conn.assigns.viewer
    params = params!(conn, "app.bsky.feed.getQuotes")
    labelers = labelers(conn)
    uri = params["uri"]

    %{uris: uris, cursor: cursor} = Feeds.quotes_of(uri, params["limit"], params["cursor"])

    state =
      Hydration.new(viewer: viewer, labelers: labelers.dids)
      |> Hydration.hydrate_posts(uris)
      |> Feeds.finish_posts()

    posts =
      for quote_uri <- uris,
          not Views.viewer_block_exists?(Hydration.did_of(quote_uri), state),
          not get_in(state.post_blocks, [quote_uri, :embed]),
          post = Views.post(quote_uri, state),
          do: post

    respond_labeled(
      conn,
      labelers,
      compact(%{"uri" => uri, "cid" => params["cid"], "posts" => posts, "cursor" => cursor})
    )
  end

  def get_actor_likes(conn, _) do
    viewer = conn.assigns.viewer
    params = params!(conn, "app.bsky.feed.getActorLikes")
    labelers = labelers(conn)
    did = Feeds.resolve_actor(params["actor"])

    if is_nil(did) or is_nil(viewer) or viewer != did,
      do: raise(Error.invalid_request("Profile not found"))

    %{items: items, cursor: cursor} = Feeds.actor_likes(did, params["limit"], params["cursor"])

    state =
      Hydration.new(viewer: viewer, labelers: labelers.dids)
      |> Hydration.hydrate_feed_items(items)
      |> Feeds.finish_posts()

    items = Enum.reject(items, &Views.viewer_block_exists?(Hydration.did_of(&1.post), state))
    respond_feed(conn, labelers, items, cursor, state)
  end

  # ----------------------------------------------------------- custom feeds

  def get_feed(conn, _) do
    viewer = conn.assigns.viewer
    params = params!(conn, "app.bsky.feed.getFeed")
    labelers = labelers(conn)

    passthrough =
      for h <- ["accept-language", "x-bsky-topics"],
          v <- get_req_header(conn, h),
          do: {h, v}

    %{items: items, cursor: cursor, req_id: req_id, headers: headers} =
      params["feed"]
      |> Feeds.feed_skeleton(
        limit: params["limit"],
        cursor: params["cursor"],
        headers: passthrough
      )
      |> ok!()

    state =
      Hydration.new(viewer: viewer, labelers: labelers.dids)
      |> Hydration.hydrate_feed_items(items)
      |> Feeds.finish_posts()

    feed =
      for item <- items,
          no_blocks_or_mutes?(item, state),
          view = Views.feed_view_post(item, state) do
        compact(Map.merge(view, %{"feedContext" => item[:feed_context], "reqId" => req_id}))
      end

    conn
    |> then(&Enum.reduce(headers, &1, fn {k, v}, c -> put_resp_header(c, k, v) end))
    |> respond_labeled(labelers, compact(%{"feed" => feed, "cursor" => cursor}))
  end

  def get_feed_generator(conn, _) do
    viewer = conn.assigns.viewer
    params = params!(conn, "app.bsky.feed.getFeedGenerator")
    labelers = labelers(conn)
    feed = params["feed"]

    state =
      Hydration.new(viewer: viewer, labelers: labelers.dids)
      |> Hydration.hydrate_feed_gens([feed])

    info = state.feed_gens[feed] || raise(Error.invalid_request("could not find feed"))
    # upstream resolves the generator's identity and requires its #bsky_fg service
    _endpoint = ok!(Feeds.feed_gen_endpoint(info.record["did"]))

    view =
      Views.feed_generator(feed, state) || raise(Error.invalid_request("could not find feed"))

    respond_labeled(conn, labelers, %{"view" => view, "isOnline" => true, "isValid" => true})
  end

  def get_feed_generators(conn, _) do
    viewer = conn.assigns.viewer
    params = params!(with_repeated(conn, ["feeds"]), "app.bsky.feed.getFeedGenerators")
    labelers = labelers(conn)
    feeds = params["feeds"] || []

    state =
      Hydration.new(viewer: viewer, labelers: labelers.dids) |> Hydration.hydrate_feed_gens(feeds)

    views = feeds |> Enum.map(&Views.feed_generator(&1, state)) |> Enum.reject(&is_nil/1)
    respond_labeled(conn, labelers, %{"feeds" => views})
  end

  def get_actor_feeds(conn, _) do
    viewer = conn.assigns.viewer
    params = params!(conn, "app.bsky.feed.getActorFeeds")
    labelers = labelers(conn)
    did = actor!(params["actor"])

    %{uris: uris, cursor: cursor} = Feeds.actor_feeds(did, params["limit"], params["cursor"])

    state =
      Hydration.new(viewer: viewer, labelers: labelers.dids) |> Hydration.hydrate_feed_gens(uris)

    views = uris |> Enum.map(&Views.feed_generator(&1, state)) |> Enum.reject(&is_nil/1)
    respond_labeled(conn, labelers, compact(%{"feeds" => views, "cursor" => cursor}))
  end

  def get_list_feed(conn, _) do
    viewer = conn.assigns.viewer
    params = params!(conn, "app.bsky.feed.getListFeed")
    labelers = labelers(conn)
    list = params["list"]

    %{items: items, cursor: cursor} = Feeds.list_feed(list, params["limit"], params["cursor"])
    list_creator = Hydration.did_of(list)

    state =
      Hydration.new(viewer: viewer, labelers: labelers.dids)
      |> Hydration.hydrate_feed_items(items)
      |> Feeds.finish_posts()
      |> Hydration.hydrate_bidirectional_blocks(
        Enum.map(items, &{list_creator, Hydration.did_of(&1.post)})
      )

    items =
      Enum.filter(items, fn item ->
        no_blocks_or_mutes?(item, state) and
          not Hydration.block_between?(state, list_creator, Hydration.did_of(item.post))
      end)

    respond_feed(conn, labelers, items, cursor, state)
  end

  # ---------------------------------------------------------------- search

  def search_posts(conn, _) do
    viewer = conn.assigns.viewer
    params = params!(with_repeated(conn, ["tag"]), "app.bsky.feed.searchPosts")
    labelers = labelers(conn)

    %{q: q, author: author} = Feeds.parse_search_query(params["q"], params["author"])

    author_did =
      case author do
        nil -> nil
        a -> Feeds.resolve_actor(a) || raise(Error.invalid_request("Profile not found"))
      end

    %{uris: uris, cursor: cursor, hits_total: total} =
      case Feeds.search_posts(q, author_did, params["limit"], params["cursor"]) do
        {:ok, result} -> result
        {:error, :malformed_cursor} -> raise Error.invalid_request("Malformed cursor")
      end

    state =
      Hydration.new(viewer: viewer, labelers: labelers.dids)
      |> Hydration.hydrate_posts(uris)
      |> Feeds.finish_posts()

    posts =
      for uri <- uris,
          state.posts[uri],
          creator = Hydration.did_of(uri),
          creator == viewer or not Views.viewer_block_exists?(creator, state),
          post = Views.post(uri, state),
          do: post

    respond_labeled(
      conn,
      labelers,
      compact(%{"posts" => posts, "cursor" => cursor, "hitsTotal" => total})
    )
  end

  # ------------------------------------------------------------ the rest

  # a feed generator's own method (upstream: served by the feedgen, not the AppView)
  def describe_feed_generator(_conn, _), do: {:error, Error.not_implemented()}

  # DESIGN §15.4: no discovery in v1
  def get_popular_feed_generators(conn, _) do
    _ = params!(conn, "app.bsky.unspecced.getPopularFeedGenerators")
    respond_labeled(conn, labelers(conn), %{"feeds" => []})
  end

  # --------------------------------------------------------------- helpers

  defp viewer!(conn), do: conn.assigns.viewer || raise(Error.auth_required())

  defp ok!({:ok, value}), do: value

  defp ok!({:error, {status, name, message}}),
    do: raise(%Error{status: status, name: name, message: message})

  defp actor!(identifier),
    do: Feeds.resolve_actor(identifier) || raise(Error.invalid_request("Profile not found"))

  # upstream noBlocksOrMutes
  defp no_blocks_or_mutes?(item, state) do
    bam = Views.feed_item_blocks_and_mutes(item, state)

    not bam.author_blocked and not bam.author_muted and not bam.originator_blocked and
      not bam.originator_muted and not bam.ancestor_author_blocked
  end

  defp respond_feed(conn, labelers, items, cursor, state) do
    feed = items |> Enum.map(&Views.feed_view_post(&1, state)) |> Enum.reject(&is_nil/1)
    respond_labeled(conn, labelers, compact(%{"feed" => feed, "cursor" => cursor}))
  end

  defp respond_labeled(conn, labelers, body) do
    conn
    |> put_resp_header("atproto-content-labelers", format_labelers(labelers))
    |> respond(body)
  end

  defp compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()

  # Upstream parseLabelerHeader / defaultLabelerHeader: `did[;redact],…`; an
  # unparseable header falls back to the instance defaults (all redacting).
  @doc false
  def labelers(conn) do
    case get_req_header(conn, "atproto-accept-labelers") do
      [] ->
        default_labelers()

      [header | _] ->
        parsed =
          header
          |> String.split(",")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.reduce_while({[], MapSet.new()}, fn item, {dids, redact} ->
            [did | params] = item |> String.split(";") |> Enum.map(&String.trim/1)

            if Syntax.valid_did?(did),
              do:
                {:cont,
                 {dids ++ [did],
                  if("redact" in params, do: MapSet.put(redact, did), else: redact)}},
              else: {:halt, nil}
          end)

        case parsed do
          nil -> default_labelers()
          {dids, redact} -> %{dids: Enum.uniq(dids), redact: redact}
        end
    end
  end

  defp default_labelers do
    dids = Config.default_labelers()
    %{dids: dids, redact: MapSet.new(dids)}
  end

  defp format_labelers(%{dids: dids, redact: redact}) do
    dids
    |> Enum.map(&if(MapSet.member?(redact, &1), do: &1 <> ";redact", else: &1))
    |> Enum.join(",")
  end

  # Plug keeps the last value of a repeated query key (`uris=a&uris=b`); XRPC
  # array params are sent that way, so collect every value for these keys.
  defp with_repeated(conn, keys) do
    pairs = URI.query_decoder(conn.query_string) |> Enum.to_list()

    query_params =
      Enum.reduce(keys, conn.query_params, fn key, acc ->
        values = for {k, v} <- pairs, k == key or k == key <> "[]", do: v
        if values == [], do: acc, else: Map.put(acc, key, values)
      end)

    %{conn | query_params: query_params}
  end
end
