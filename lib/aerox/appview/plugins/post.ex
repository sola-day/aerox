defmodule Aerox.AppView.Plugins.Post do
  @moduledoc """
  `app.bsky.feed.post` (upstream `plugins/post.ts`): the post row, its feed
  item, embeds (images / external / record / video, `recordWithMedia`
  split), quotes, reply validation (`invalidReplyRoot`,
  `violatesThreadGate`), embedding rules (`violatesEmbeddingRules`), and
  the mention / quote / reply notifications up to five ancestors — with the
  out-of-order case (descendants already indexed) notifying upwards.
  """
  use Aerox.AppView.Plugin
  alias Aerox.AppView.Plugin
  alias Aerox.AppView.Schema.{Post, PostAgg, ProfileAgg, Quote, FeedItem, Record}
  alias Aerox.AppView.Schema.{PostEmbedExternal, PostEmbedImage, PostEmbedRecord, PostEmbedVideo}
  alias Aerox.AppView.ThreadGates

  @reply_notif_depth 5

  def collection, do: "app.bsky.feed.post"

  # ------------------------------------------------------------------ insert

  def insert(uri, cid, record, indexed_at) do
    creator = uri_did(uri)
    created = created_at(record["createdAt"])

    attrs = %{
      uri: uri,
      cid: cid,
      creator: creator,
      text: record["text"] || "",
      reply_root: get_in(record, ["reply", "root", "uri"]),
      reply_root_cid: cid_string(get_in(record, ["reply", "root", "cid"])),
      reply_parent: get_in(record, ["reply", "parent", "uri"]),
      reply_parent_cid: cid_string(get_in(record, ["reply", "parent", "cid"])),
      langs: non_empty(record["langs"]),
      tags: non_empty(record["tags"]),
      created_at: created,
      indexed_at: indexed_at
    }

    case insert_row(Post, attrs) do
      nil ->
        nil

      post ->
        insert_row(FeedItem, %{
          uri: uri,
          cid: cid,
          type: "post",
          post_uri: uri,
          originator_did: creator,
          sort_at: min_dt(created, indexed_at)
        })

        post = if record["reply"], do: validate_reply(post, record["reply"]), else: post
        facets = facets(record)
        {post, embeds} = index_embeds(post, record, created, indexed_at)
        threadgate = ThreadGates.gate_record(post.reply_root || post.uri)

        %{
          post: post,
          facets: facets,
          embeds: embeds,
          ancestors: ancestors(post.uri),
          descendents: descendents(post.uri),
          threadgate: threadgate,
          # what the processor and aggregates need at the top level
          uri: post.uri,
          cid: post.cid,
          creator: post.creator,
          sort_at: post.sort_at
        }
    end
  end

  defp non_empty(list) when is_list(list) and list != [], do: Enum.filter(list, &is_binary/1)
  defp non_empty(_), do: nil

  defp validate_reply(post, reply) do
    root_uri = get_in(reply, ["root", "uri"])
    parent_uri = get_in(reply, ["parent", "uri"])
    refs = reply_refs(root_uri, parent_uri)

    invalid_root =
      case refs.parent do
        nil -> true
        parent -> invalid_reply_root?(reply, parent)
      end

    violates =
      ThreadGates.violates?(
        post.creator,
        uri_did(root_uri),
        refs.root && refs.root.record,
        refs.gate
      )

    if invalid_root or violates do
      Repo.update_all(from(p in Post, where: p.uri == ^post.uri),
        set: [invalid_reply_root: invalid_root, violates_thread_gate: violates]
      )

      %{post | invalid_reply_root: invalid_root, violates_thread_gate: violates}
    else
      post
    end
  end

  defp reply_refs(root_uri, parent_uri) do
    gate_uri = ThreadGates.gate_uri(root_uri)
    uris = Enum.reject([root_uri, parent_uri, gate_uri], &is_nil/1)

    rows =
      Repo.all(
        from(r in Record,
          left_join: p in Post,
          on: p.uri == r.uri,
          where: r.uri in ^uris,
          select: {r.uri, r.json, p}
        )
      )

    find = fn uri -> Enum.find(rows, &(elem(&1, 0) == uri)) end

    %{
      root: with({_, json, post} <- find.(root_uri), do: %{record: json, post: post}),
      parent: with({_, json, post} <- find.(parent_uri), do: %{record: json, post: post}),
      gate: with({_, json, _} <- find.(gate_uri), do: json)
    }
  end

  # upstream invalidReplyRoot
  defp invalid_reply_root?(reply, %{record: parent_record, post: parent_post}) do
    root = get_in(reply, ["root", "uri"])
    parent = get_in(reply, ["parent", "uri"])

    cond do
      parent_post && parent_post.invalid_reply_root == true -> true
      parent == root -> not is_nil(parent_record["reply"])
      true -> get_in(parent_record, ["reply", "root", "uri"]) != root
    end
  end

  defp facets(record) do
    for facet <- record["facets"] || [],
        feature <- facet["features"] || [],
        f = facet_feature(feature),
        do: f
  end

  defp facet_feature(%{"$type" => "app.bsky.richtext.facet#mention", "did" => did}),
    do: {:mention, did}

  defp facet_feature(%{"$type" => "app.bsky.richtext.facet#link", "uri" => uri}), do: {:link, uri}
  defp facet_feature(_), do: nil

  # ------------------------------------------------------------------ embeds

  defp index_embeds(post, record, created, indexed_at) do
    embeds = separate_embeds(record["embed"])

    Enum.reduce(embeds, {post, []}, fn embed, {post, acc} ->
      case embed do
        %{"$type" => "app.bsky.embed.images", "images" => images} ->
          rows =
            images
            |> Enum.with_index()
            |> Enum.map(fn {img, i} ->
              %{
                post_uri: post.uri,
                position: i,
                image_cid: blob_cid(img["image"]),
                alt: img["alt"] || ""
              }
            end)
            |> Enum.reject(&is_nil(&1.image_cid))

          if rows != [], do: Repo.insert_all(PostEmbedImage, rows, on_conflict: :nothing)
          {post, [{:images, rows} | acc]}

        %{"$type" => "app.bsky.embed.external", "external" => ext} ->
          row = %{
            post_uri: post.uri,
            uri: ext["uri"],
            title: ext["title"] || "",
            description: ext["description"] || "",
            thumb_cid: ext["thumb"] && blob_cid(ext["thumb"])
          }

          Repo.insert_all(PostEmbedExternal, [row], on_conflict: :nothing)
          {post, [{:external, row} | acc]}

        %{"$type" => "app.bsky.embed.record", "record" => %{"uri" => embed_uri} = ref} ->
          embed_cid = cid_string(ref["cid"])

          Repo.insert_all(
            PostEmbedRecord,
            [%{post_uri: post.uri, embed_uri: embed_uri, embed_cid: embed_cid}],
            on_conflict: :nothing
          )

          post =
            if uri_collection(embed_uri) == "app.bsky.feed.post",
              do: index_quote(post, embed_uri, embed_cid, created, indexed_at),
              else: post

          {post, [{:record, %{embed_uri: embed_uri, embed_cid: embed_cid}} | acc]}

        %{"$type" => "app.bsky.embed.video", "video" => video} = v ->
          row = %{post_uri: post.uri, video_cid: blob_cid(video), alt: v["alt"]}
          if row.video_cid, do: Repo.insert_all(PostEmbedVideo, [row], on_conflict: :nothing)
          {post, [{:video, row} | acc]}

        _ ->
          {post, acc}
      end
    end)
    |> then(fn {post, acc} -> {post, Enum.reverse(acc)} end)
  end

  defp separate_embeds(nil), do: []

  defp separate_embeds(%{
         "$type" => "app.bsky.embed.recordWithMedia",
         "record" => record,
         "media" => media
       }),
       do: [Map.put(record, "$type", "app.bsky.embed.record"), media]

  defp separate_embeds(embed), do: [embed]

  defp index_quote(post, subject, subject_cid, created, indexed_at) do
    insert_row(Quote, %{
      uri: post.uri,
      cid: post.cid,
      subject: subject,
      subject_cid: subject_cid,
      created_at: created,
      indexed_at: indexed_at
    })

    n = count(from(q in Quote, where: q.subject == ^subject))
    Plugin.set_aggregate(PostAgg, :uri, subject, :quote_count, n)

    if ThreadGates.embedding_disabled?(subject, post.creator) do
      Repo.update_all(from(p in Post, where: p.uri == ^post.uri),
        set: [violates_embedding_rules: true]
      )

      %{post | violates_embedding_rules: true}
    else
      post
    end
  end

  # ----------------------------------------------------------------- threads

  @doc "Upstream getAncestorsAndSelfQb: `[%{uri, height}]` including self at height 0."
  def ancestors(uri, height \\ @reply_notif_depth) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE ancestor(uri, ancestor_uri, height) AS (
          SELECT post.uri, post.reply_parent, 0 FROM post WHERE post.uri = $1
          UNION ALL
          SELECT post.uri, post.reply_parent, ancestor.height + 1
          FROM post JOIN ancestor ON ancestor.ancestor_uri = post.uri
          WHERE ancestor.height < $2
        )
        SELECT uri, height FROM ancestor
        """,
        [uri, height]
      )

    for [u, h] <- rows, do: %{uri: u, height: h}
  end

  @doc "Upstream getDescendentsQb joined with post: `[%{uri, depth, cid, creator, sort_at}]`."
  def descendents(uri, depth \\ @reply_notif_depth) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE descendent(uri, depth) AS (
          SELECT post.uri, 1 FROM post WHERE post.reply_parent = $1 AND 1 <= $2
          UNION ALL
          SELECT post.uri, descendent.depth + 1
          FROM post JOIN descendent ON descendent.uri = post.reply_parent
          WHERE descendent.depth < $2
        )
        SELECT d.uri, d.depth, post.cid, post.creator, post.sort_at
        FROM descendent d JOIN post ON post.uri = d.uri
        """,
        [uri, depth]
      )

    for [u, d, cid, creator, sort_at] <- rows,
        do: %{uri: u, depth: d, cid: cid, creator: creator, sort_at: sort_at}
  end

  # ------------------------------------------------------------ notifications

  def notifs_for_insert(%{post: post} = obj) do
    notified = MapSet.new([post.creator])

    maybe = fn {notifs, seen}, notif ->
      if MapSet.member?(seen, notif.did),
        do: {notifs, seen},
        else: {[notif | notifs], MapSet.put(seen, notif.did)}
    end

    base = %{
      author: post.creator,
      record_uri: post.uri,
      record_cid: post.cid,
      sort_at: post.sort_at
    }

    acc = {[], notified}

    acc =
      Enum.reduce(obj.facets, acc, fn
        {:mention, did}, acc ->
          maybe.(acc, Map.merge(base, %{did: did, reason: "mention", reason_subject: nil}))

        _, acc ->
          acc
      end)

    acc =
      if post.violates_embedding_rules do
        acc
      else
        Enum.reduce(obj.embeds, acc, fn
          {:record, %{embed_uri: embed_uri}}, acc ->
            if uri_collection(embed_uri) == "app.bsky.feed.post",
              do:
                maybe.(
                  acc,
                  Map.merge(base, %{
                    did: uri_did(embed_uri),
                    reason: "quote",
                    reason_subject: embed_uri
                  })
                ),
              else: acc

          _, acc ->
            acc
        end)
      end

    if post.violates_thread_gate do
      elem(acc, 0) |> Enum.reverse()
    else
      hidden = (obj.threadgate && obj.threadgate["hiddenReplies"]) || []

      acc =
        Enum.reduce_while(obj.ancestors, acc, fn ancestor, acc ->
          cond do
            ancestor.uri == post.uri ->
              {:cont, acc}

            ancestor.height < @reply_notif_depth ->
              acc =
                maybe.(
                  acc,
                  Map.merge(base, %{
                    did: uri_did(ancestor.uri),
                    reason: "reply",
                    reason_subject: ancestor.uri
                  })
                )

              if ancestor.uri in hidden, do: {:halt, acc}, else: {:cont, acc}

            true ->
              {:cont, acc}
          end
        end)

      # descendants already indexed: notify this post and its ancestors about them
      acc =
        for d <- obj.descendents,
            a <- obj.ancestors,
            d.depth + a.height < @reply_notif_depth,
            reduce: acc do
          acc ->
            maybe.(acc, %{
              did: uri_did(a.uri),
              author: d.creator,
              record_uri: d.uri,
              record_cid: d.cid,
              reason: "reply",
              reason_subject: a.uri,
              sort_at: d.sort_at
            })
        end

      elem(acc, 0) |> Enum.reverse()
    end
  end

  def notifs_for_delete(deleted, _replaced), do: %{notifs: [], to_delete: [deleted.uri]}

  # ------------------------------------------------------------------ delete

  def delete(uri) do
    Repo.delete_all(from(f in FeedItem, where: f.post_uri == ^uri))
    Repo.delete_all(from(q in Quote, where: q.uri == ^uri or q.subject == ^uri))
    Repo.delete_all(from(e in PostEmbedImage, where: e.post_uri == ^uri))
    Repo.delete_all(from(e in PostEmbedExternal, where: e.post_uri == ^uri))
    embed_record = Repo.one(from(e in PostEmbedRecord, where: e.post_uri == ^uri))
    Repo.delete_all(from(e in PostEmbedRecord, where: e.post_uri == ^uri))
    Repo.delete_all(from(e in PostEmbedVideo, where: e.post_uri == ^uri))

    case delete_rows(Post, uri: uri) do
      nil ->
        nil

      post ->
        %{
          post: post,
          facets: [],
          embeds:
            if(embed_record,
              do: [
                {:record, %{embed_uri: embed_record.embed_uri, embed_cid: embed_record.embed_cid}}
              ],
              else: []
            ),
          ancestors: [],
          descendents: [],
          threadgate: nil,
          uri: post.uri,
          cid: post.cid,
          creator: post.creator,
          sort_at: post.sort_at
        }
    end
  end

  # -------------------------------------------------------------- aggregates

  def update_aggregates(%{post: post, embeds: embeds}) do
    if post.reply_parent do
      n =
        count(
          from(p in Post,
            where:
              p.reply_parent == ^post.reply_parent and
                (is_nil(p.invalid_reply_root) or p.invalid_reply_root == false) and
                (is_nil(p.violates_thread_gate) or p.violates_thread_gate == false)
          )
        )

      Plugin.set_aggregate(PostAgg, :uri, post.reply_parent, :reply_count, n)
    end

    posts = count(from(p in Post, where: p.creator == ^post.creator))
    Plugin.set_aggregate(ProfileAgg, :did, post.creator, :posts_count, posts)

    for {:record, %{embed_uri: subject}} <- embeds,
        uri_collection(subject) == "app.bsky.feed.post" do
      n = count(from(q in Quote, where: q.subject == ^subject))
      Plugin.set_aggregate(PostAgg, :uri, subject, :quote_count, n)
    end

    :ok
  end
end
