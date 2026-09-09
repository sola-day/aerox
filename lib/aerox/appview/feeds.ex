defmodule Aerox.AppView.Feeds do
  @moduledoc """
  Feed skeletons (DESIGN §15.3–15.4, upstream `data-plane/server/routes/{feeds,
  likes,reposts,quotes,threads,search,feed-gens}.ts`): the queries that turn a
  request into a list of URIs, paginated with the `TimeCidKeyset` cursor.
  Feed-shaped results are `%{items: [%{post: uri, repost: uri | nil,
  author_pinned: bool}], cursor: cursor | nil}`.

  Also the pieces of hydration the read path needs that
  `Aerox.AppView.Hydration` does not provide: thread contexts (the root
  author's likes), viewer/label state for post authors outside feed items,
  actor identifier resolution, and the feed generator call (`getFeed`).
  """
  import Ecto.Query
  require Aerox.AppView.Cursor
  alias Aerox.ATProto.{Lexicon, Syntax}
  alias Aerox.AppView.{Config, Cursor, Hydration, Repo}
  alias Aerox.AppView.Plugins.Post, as: PostPlugin
  alias Aerox.AppView.Schema, as: S

  @type feed_item :: %{post: String.t(), repost: String.t() | nil, author_pinned: boolean}
  @type feed :: %{items: [feed_item], cursor: String.t() | nil}

  # ---------------------------------------------------------------- actors

  @doc "An at-identifier (DID or handle) → DID: the index first, then live resolution. `nil` when unknown."
  @spec resolve_actor(String.t()) :: String.t() | nil
  def resolve_actor("did:" <> _ = did), do: did

  def resolve_actor(handle) when is_binary(handle) do
    handle = handle |> String.trim() |> String.trim_leading("@") |> String.downcase()

    case Repo.one(from(a in S.Actor, where: a.handle == ^handle, select: a.did)) do
      nil ->
        case Aerox.Identity.resolve_handle(Aerox.AppView.Identity, handle) do
          {:ok, did} -> did
          _ -> nil
        end

      did ->
        did
    end
  end

  def resolve_actor(_), do: nil

  # -------------------------------------------------------------- timeline

  @doc """
  Upstream `getTimeline` (data-plane `feeds.ts`): feed items whose originator
  the viewer follows, plus the viewer's own, newest first. DESIGN §15.4's
  default reply rule on top (upstream's pre-dataplane `getTimeline` filter):
  a reply by a followed account is shown only when the parent's author is
  the viewer, the replier, or someone the viewer follows. Reposts and the
  viewer's own items are never filtered.
  """
  @spec timeline(String.t(), pos_integer, String.t() | nil) :: feed
  def timeline(viewer, limit, cursor) do
    if Cursor.clearly_bad?(cursor) do
      %{items: [], cursor: nil}
    else
      followed_parent =
        from(f in S.Follow,
          where:
            f.creator == ^viewer and
              f.subject_did == fragment("split_part(?, '/', 3)", parent_as(:post).reply_parent)
        )

      rows =
        from(fi in S.FeedItem,
          as: :feed_item,
          join: p in S.Post,
          as: :post,
          on: p.uri == fi.post_uri,
          where:
            fi.originator_did == ^viewer or
              (exists(
                 from(f in S.Follow,
                   where:
                     f.creator == ^viewer and
                       f.subject_did == parent_as(:feed_item).originator_did
                 )
               ) and
                 (fi.type == "repost" or is_nil(p.reply_parent) or
                    fragment("split_part(?, '/', 3)", p.reply_parent) == ^viewer or
                    fragment("split_part(?, '/', 3)", p.reply_parent) == p.creator or
                    exists(followed_parent))),
          select: %{uri: fi.uri, post_uri: fi.post_uri, cid: fi.cid, sort_at: fi.sort_at}
        )
        |> Cursor.paginate(cursor, limit)
        |> Repo.all()

      %{items: Enum.map(rows, &feed_item_from_row/1), cursor: Cursor.next(rows, limit)}
    end
  end

  defp feed_item_from_row(row) do
    %{
      post: row.post_uri,
      repost: if(row.uri == row.post_uri, do: nil, else: row.uri),
      author_pinned: false
    }
  end

  # ----------------------------------------------------------- author feed

  @filters ~w(posts_with_replies posts_no_replies posts_with_media posts_and_author_threads posts_with_video)

  @doc "Upstream `getAuthorFeed` (data-plane `feeds.ts`) with the five `filter` values; `include_pins` prepends the pinned post on the first page."
  @spec author_feed(String.t(), String.t(), pos_integer, String.t() | nil, boolean) :: feed
  def author_feed(did, filter, limit, cursor, include_pins \\ false) when filter in @filters do
    if Cursor.clearly_bad?(cursor) do
      %{items: [], cursor: nil}
    else
      base =
        from(fi in S.FeedItem,
          as: :feed_item,
          join: p in S.Post,
          as: :post,
          on: p.uri == fi.post_uri,
          where: fi.originator_did == ^did,
          select: %{uri: fi.uri, post_uri: fi.post_uri, cid: fi.cid, sort_at: fi.sort_at}
        )

      query =
        case filter do
          "posts_with_media" ->
            where(
              base,
              [feed_item: fi],
              fi.type == "post" and
                exists(
                  from(i in S.PostEmbedImage,
                    where: i.post_uri == parent_as(:feed_item).post_uri,
                    select: 1
                  )
                )
            )

          "posts_with_video" ->
            where(
              base,
              [feed_item: fi],
              fi.type == "post" and
                exists(
                  from(v in S.PostEmbedVideo,
                    where: v.post_uri == parent_as(:feed_item).post_uri,
                    select: 1
                  )
                )
            )

          "posts_no_replies" ->
            where(base, [feed_item: fi, post: p], is_nil(p.reply_parent) or fi.type == "repost")

          "posts_and_author_threads" ->
            where(
              base,
              [feed_item: fi, post: p],
              fi.type == "repost" or is_nil(p.reply_parent) or
                like(p.reply_root, ^"at://#{did}/%")
            )

          _ ->
            base
        end

      rows = query |> Cursor.paginate(cursor, limit) |> Repo.all()
      items = Enum.map(rows, &feed_item_from_row/1)

      items =
        case if(include_pins and is_nil(cursor), do: pinned_post(did)) do
          nil ->
            items

          pinned ->
            [
              %{post: pinned, repost: nil, author_pinned: true}
              | Enum.reject(items, &(&1.post == pinned))
            ]
        end

      %{items: items, cursor: Cursor.next(rows, limit)}
    end
  end

  defp pinned_post(did) do
    case Repo.one(from(p in S.Profile, where: p.creator == ^did, select: p.pinned_post)) do
      nil -> nil
      uri -> if Hydration.did_of(uri) == did, do: uri
    end
  end

  @doc """
  Upstream `SelfThreadTracker` (getAuthorFeed.ts): for `posts_and_author_threads`,
  a reply stays only when every ancestor up to the root is in the page (a
  complete self-thread). Reposts and the pinned item always pass.
  """
  @spec self_thread_filter([feed_item], Hydration.state()) :: [feed_item]
  def self_thread_filter(items, state) do
    feed_uris = for %{repost: nil} = i <- items, into: MapSet.new(), do: i.post

    Enum.filter(items, fn item ->
      item.repost != nil or item.author_pinned or
        self_thread_ok?(item.post, feed_uris, state, MapSet.new())
    end)
  end

  defp self_thread_ok?(uri, feed_uris, state, seen) do
    cond do
      MapSet.member?(seen, uri) ->
        false

      not MapSet.member?(feed_uris, uri) ->
        false

      is_nil(state.posts[uri]) ->
        false

      true ->
        case get_in(state.posts[uri].record, ["reply", "parent", "uri"]) do
          nil -> true
          parent -> self_thread_ok?(parent, feed_uris, state, MapSet.put(seen, uri))
        end
    end
  end

  # ------------------------------------------------------------- list feed

  @doc "Upstream `getListFeed`: posts by the list's members, newest first."
  @spec list_feed(String.t(), pos_integer, String.t() | nil) :: feed
  def list_feed(list_uri, limit, cursor) do
    if Cursor.clearly_bad?(cursor) do
      %{items: [], cursor: nil}
    else
      rows =
        from(p in S.Post,
          join: i in S.ListItem,
          on: i.subject_did == p.creator,
          where: i.list_uri == ^list_uri,
          select: %{uri: p.uri, cid: p.cid, sort_at: p.sort_at}
        )
        |> Cursor.paginate(cursor, limit)
        |> Repo.all()

      %{
        items: Enum.map(rows, &%{post: &1.uri, repost: nil, author_pinned: false}),
        cursor: Cursor.next(rows, limit)
      }
    end
  end

  # --------------------------------------------------------------- threads

  @doc "Upstream `getThread` (data-plane `threads.ts`): the anchor, its ancestors up to `parent_height`, its descendants down to `depth` (newest first)."
  @spec thread(String.t(), non_neg_integer, non_neg_integer) :: [String.t()]
  def thread(uri, parent_height, depth) do
    ancestors = uri |> PostPlugin.ancestors(parent_height) |> Enum.map(& &1.uri)

    descendents =
      uri
      |> PostPlugin.descendents(depth)
      |> Enum.sort_by(&naive(&1.sort_at), {:desc, NaiveDateTime})
      |> Enum.map(& &1.uri)

    Enum.uniq(ancestors ++ descendents)
  end

  defp naive(%DateTime{} = dt), do: DateTime.to_naive(dt)
  defp naive(%NaiveDateTime{} = dt), do: dt

  @doc "Upstream `getThreadContexts`: for each hydrated post, the root author's like of it (`rootAuthorLike`)."
  @spec hydrate_thread_contexts(Hydration.state(), [String.t()]) :: Hydration.state()
  def hydrate_thread_contexts(state, uris) do
    refs =
      for uri <- uris,
          post = state.posts[uri],
          root_author = Hydration.did_of(get_in(post.record, ["reply", "root", "uri"]) || uri),
          root_author,
          do: {root_author, uri}

    likes =
      refs
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.flat_map(fn {author, subjects} ->
        Repo.all(
          from(l in S.Like,
            where: l.creator == ^author and l.subject in ^subjects,
            select: {l.subject, l.uri}
          )
        )
      end)
      |> Map.new()

    contexts = for {_, uri} <- refs, into: %{}, do: {uri, %{like: likes[uri]}}
    %{state | thread_contexts: Map.merge(state.thread_contexts, contexts)}
  end

  @doc """
  Finishes a post hydration for presentation: viewer state and labels for
  the authors of every hydrated post (what upstream's `hydratePosts`
  includes and `Hydration.hydrate_posts/2` leaves to `hydrate_feed_items/2`),
  and a complete `post_blocks` entry (`parent`/`root`/`embed`, default
  false) for every post, which `Views.reply_ref/2` reads as booleans.
  """
  @spec finish_posts(Hydration.state()) :: Hydration.state()
  def finish_posts(state) do
    posts = state.posts |> Map.values() |> Enum.reject(&is_nil/1)
    dids = posts |> Enum.map(& &1.creator) |> Enum.uniq()

    blocks =
      for p <- posts,
          into: %{},
          do:
            {p.uri,
             Map.merge(
               %{parent: false, root: false, embed: false},
               state.post_blocks[p.uri] || %{}
             )}

    state = %{state | post_blocks: Map.merge(state.post_blocks, blocks)}

    state
    |> Hydration.hydrate_profile_viewers(dids)
    |> Hydration.hydrate_labels(dids)
  end

  # ------------------------------------------------- likes / reposts / quotes

  @doc "Upstream `getLikesBySubjectSorted`: like URIs of a subject, newest first."
  @spec likes_of(String.t(), pos_integer, String.t() | nil) :: %{uris: [String.t()], cursor: term}
  def likes_of(subject, limit, cursor), do: by_subject(S.Like, subject, limit, cursor)

  @doc "Upstream `getRepostsBySubject`."
  @spec reposts_of(String.t(), pos_integer, String.t() | nil) :: %{
          uris: [String.t()],
          cursor: term
        }
  def reposts_of(subject, limit, cursor), do: by_subject(S.Repost, subject, limit, cursor)

  @doc "Upstream `getQuotesBySubjectSorted`: quoting post URIs."
  @spec quotes_of(String.t(), pos_integer, String.t() | nil) :: %{
          uris: [String.t()],
          cursor: term
        }
  def quotes_of(subject, limit, cursor), do: by_subject(S.Quote, subject, limit, cursor)

  defp by_subject(schema, subject, limit, cursor) do
    if Cursor.clearly_bad?(cursor) do
      %{uris: [], cursor: nil}
    else
      rows =
        from(x in schema,
          where: x.subject == ^subject,
          select: %{uri: x.uri, cid: x.cid, sort_at: x.sort_at}
        )
        |> Cursor.paginate(cursor, limit)
        |> Repo.all()

      %{uris: Enum.map(rows, & &1.uri), cursor: Cursor.next(rows, limit)}
    end
  end

  @doc "Upstream `getActorLikes`: the posts an actor liked, as feed items, newest like first."
  @spec actor_likes(String.t(), pos_integer, String.t() | nil) :: feed
  def actor_likes(did, limit, cursor) do
    if Cursor.clearly_bad?(cursor) do
      %{items: [], cursor: nil}
    else
      rows =
        from(l in S.Like,
          where: l.creator == ^did,
          select: %{uri: l.uri, subject: l.subject, cid: l.cid, sort_at: l.sort_at}
        )
        |> Cursor.paginate(cursor, limit)
        |> Repo.all()

      %{
        items: Enum.map(rows, &%{post: &1.subject, repost: nil, author_pinned: false}),
        cursor: Cursor.next(rows, limit)
      }
    end
  end

  @doc "Upstream `getActorFeeds`: an actor's feed generators, newest first."
  @spec actor_feeds(String.t(), pos_integer, String.t() | nil) :: %{
          uris: [String.t()],
          cursor: term
        }
  def actor_feeds(did, limit, cursor) do
    if Cursor.clearly_bad?(cursor) do
      %{uris: [], cursor: nil}
    else
      rows =
        from(f in S.FeedGenerator,
          where: f.creator == ^did,
          select: %{uri: f.uri, cid: f.cid, sort_at: f.sort_at}
        )
        |> Cursor.paginate(cursor, limit)
        |> Repo.all()

      %{uris: Enum.map(rows, & &1.uri), cursor: Cursor.next(rows, limit)}
    end
  end

  # ---------------------------------------------------------------- search

  @doc """
  Upstream `parsePostSearchQuery` (data-plane `util.ts`): splits `q` on
  unquoted spaces; `did:…`, `from:x` and `author:x` terms set the author
  (`q` wins over the `author` param); the rest is the search text.
  """
  @spec parse_search_query(String.t(), String.t() | nil) :: %{
          q: String.t(),
          author: String.t() | nil
        }
  def parse_search_query(q, author \\ nil) do
    {parts, curr, _} =
      q
      |> String.graphemes()
      |> Enum.reduce({[], "", false}, fn
        " ", {parts, curr, false} ->
          {if(String.trim(curr) != "", do: [curr | parts], else: parts), "", false}

        "\"", {parts, curr, quoted} ->
          {parts, curr <> "\"", not quoted}

        c, {parts, curr, quoted} ->
          {parts, curr <> c, quoted}
      end)

    parts = if String.trim(curr) != "", do: [curr | parts], else: parts

    Enum.reduce(Enum.reverse(parts), %{q: [], author: author}, fn p, acc ->
      case String.split(p, ":", parts: 2) do
        ["did", _] -> %{acc | author: p}
        [k, v] when k in ["author", "from"] -> %{acc | author: v}
        _ -> %{acc | q: acc.q ++ [p]}
      end
    end)
    |> Map.update!(:q, &Enum.join(&1, " "))
  end

  @doc """
  Postgres substring search on `post.text` (DESIGN §15.8: `pg_trgm` ILIKE, so
  CJK runs match as substrings). The cursor is a numeric offset, as upstream's
  `searchPosts` cursor. Returns `%{uris, cursor, hits_total}`.
  """
  @spec search_posts(String.t(), String.t() | nil, pos_integer, String.t() | nil) ::
          {:ok, %{uris: [String.t()], cursor: String.t() | nil, hits_total: non_neg_integer}}
          | {:error, :malformed_cursor}
  def search_posts(q, author_did, limit, cursor) do
    with {:ok, offset} <- parse_offset(cursor),
         do: {:ok, do_search_posts(q, author_did, limit, offset)}
  end

  defp do_search_posts(q, author_did, limit, offset) do
    pattern = "%" <> escape_like(String.trim(q)) <> "%"

    base =
      from(p in S.Post, where: ilike(p.text, ^pattern))
      |> then(&if(author_did, do: where(&1, [p], p.creator == ^author_did), else: &1))

    total = Repo.aggregate(base, :count)

    uris =
      base
      |> order_by([p], desc: p.sort_at, desc: p.cid)
      |> offset(^offset)
      |> limit(^limit)
      |> select([p], p.uri)
      |> Repo.all()

    next = offset + length(uris)

    %{
      uris: uris,
      cursor: if(length(uris) >= limit and next < total, do: Integer.to_string(next)),
      hits_total: total
    }
  end

  defp parse_offset(nil), do: {:ok, 0}

  defp parse_offset(cursor) do
    case Integer.parse(cursor) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :malformed_cursor}
    end
  end

  defp escape_like(s), do: Regex.replace(~r/[\\%_]/, s, &("\\" <> &1))

  # ---------------------------------------------------------- feed generators

  @doc """
  Upstream `skeletonFromFeedGen` (getFeed.ts): resolves the feed record's
  `did` to its `#bsky_fg` service endpoint and calls
  `app.bsky.feed.getFeedSkeleton` with a service JWT issued by this AppView
  (`iss` = our service DID, signed with `Config.signing_keypair/0`, `aud` =
  the feed generator's DID, `lxm` = `getFeedSkeleton`). Returns feed items
  with `feed_context`, the cursor (dropped when the generator echoes ours
  back), `req_id`, and the `content-language` header to pass through.
  """
  @spec feed_skeleton(String.t(), keyword) ::
          {:ok,
           %{
             items: [map],
             cursor: String.t() | nil,
             req_id: String.t() | nil,
             headers: [{String.t(), String.t()}]
           }}
          | {:error, {non_neg_integer, String.t(), String.t()}}
  def feed_skeleton(feed_uri, opts) do
    limit = Keyword.fetch!(opts, :limit)
    cursor = Keyword.get(opts, :cursor)

    with {:ok, feed_did} <- feed_did(feed_uri),
         {:ok, endpoint} <- feed_gen_endpoint(feed_did) do
      jwt =
        Aerox.Auth.ServiceJWT.create(
          keypair: Config.signing_keypair(),
          iss: Config.service_did(),
          aud: feed_did,
          lxm: "app.bsky.feed.getFeedSkeleton"
        )

      query =
        %{"feed" => feed_uri, "limit" => limit}
        |> then(&if(cursor, do: Map.put(&1, "cursor", cursor), else: &1))
        |> URI.encode_query()

      url =
        String.trim_trailing(endpoint, "/") <> "/xrpc/app.bsky.feed.getFeedSkeleton?" <> query

      headers =
        [{"authorization", "Bearer " <> jwt}, {"user-agent", "AeroxAppView"}] ++
          Keyword.get(opts, :headers, [])

      http_opts =
        [headers: headers, timeout: 10_000] ++
          Keyword.take(Application.get_env(:aerox, Aerox.AppView.FeedGen, []), [
            :plug,
            :allow_private
          ])

      case Aerox.Identity.HTTP.get(url, http_opts) do
        {:ok, 200, resp_headers, body} ->
          parse_skeleton(body, resp_headers, limit, cursor)

        {:ok, status, _headers, body} when status >= 400 ->
          # a structurally valid XRPC error (auth errors etc.) passes through
          case Jason.decode(body) do
            {:ok, %{"error" => name, "message" => message}}
            when is_binary(name) and is_binary(message) ->
              {:error, {status, name, message}}

            _ ->
              {:error, {502, "UpstreamFailure", "feed unavailable"}}
          end

        _ ->
          {:error, {502, "UpstreamFailure", "feed unavailable"}}
      end
    end
  end

  defp feed_did(feed_uri) do
    case Repo.one(from(f in S.FeedGenerator, where: f.uri == ^feed_uri, select: f.feed_did)) do
      nil -> {:error, {400, "UnknownFeed", "could not find feed"}}
      did -> {:ok, did}
    end
  end

  @doc "The `#bsky_fg` (BskyFeedGenerator) service endpoint of a feed generator's DID."
  @spec feed_gen_endpoint(String.t()) ::
          {:ok, String.t()} | {:error, {non_neg_integer, String.t(), String.t()}}
  def feed_gen_endpoint(feed_did) do
    case Aerox.Identity.resolve_did(Aerox.AppView.Identity, feed_did) do
      {:ok, doc} ->
        case Aerox.ATProto.Identity.service_endpoint(doc, "#bsky_fg", "BskyFeedGenerator") do
          nil ->
            {:error,
             {400, "InvalidRequest",
              "invalid feed generator service details in did document: #{feed_did}"}}

          url ->
            {:ok, url}
        end

      _ ->
        {:error, {400, "InvalidRequest", "could not resolve identity: #{feed_did}"}}
    end
  end

  defp parse_skeleton(body, resp_headers, limit, cursor) do
    with {:ok, json} <- Jason.decode(body),
         {:ok, %{"feed" => feed} = out} <-
           Lexicon.validate_output(
             Lexicon.default_registry(),
             "app.bsky.feed.getFeedSkeleton",
             json
           ) do
      items =
        feed
        |> Enum.take(limit)
        |> Enum.map(fn item ->
          reason = item["reason"] || %{}

          %{
            post: item["post"],
            repost:
              if(reason["$type"] == "app.bsky.feed.defs#skeletonReasonRepost",
                do: reason["repost"]
              ),
            author_pinned: reason["$type"] == "app.bsky.feed.defs#skeletonReasonPin",
            feed_context: item["feedContext"]
          }
        end)

      lang =
        Enum.find_value(resp_headers, fn {k, v} ->
          if String.downcase(k) == "content-language", do: v
        end)

      {:ok,
       %{
         items: items,
         # prevents loops when the generator echoes our cursor back
         cursor: if(out["cursor"] != cursor, do: out["cursor"]),
         req_id: out["reqId"],
         headers: if(lang, do: [{"content-language", lang}], else: [])
       }}
    else
      _ -> {:error, {502, "InvalidFeedResponse", "feed provided an invalid response"}}
    end
  end

  # --------------------------------------------------------------- helpers

  @doc "A record's `createdAt` as a normalised datetime, or `fallback` (upstream normalizeDatetimeAlways)."
  @spec normalize_datetime(term, DateTime.t()) :: String.t()
  def normalize_datetime(value, fallback) do
    case value && Syntax.parse_datetime(value) do
      {:ok, dt} -> Syntax.format_datetime(dt)
      _ -> Syntax.format_datetime(fallback)
    end
  end
end
