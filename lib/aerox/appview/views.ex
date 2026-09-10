defmodule Aerox.AppView.Views do
  @moduledoc """
  Presentation (DESIGN §15.3, upstream `views/index.ts`): hydration state →
  the lexicon view objects, as JSON-ready maps with string keys. Blocked and
  missing content becomes the `#blockedPost` / `#notFoundPost` /
  `#viewBlocked` placeholders, never a silent omission.
  """
  alias Aerox.ATProto.Syntax
  alias Aerox.AppView.{Config, Hydration, ThreadGates}
  alias Aerox.ImageServer.Presets

  @invalid_handle "handle.invalid"

  # ------------------------------------------------------------ helpers

  defp img(preset, did, cid), do: Presets.url(Config.image_url(), preset, did, cid)

  defp blob_cid(%{"ref" => %{"$link" => link}}), do: link
  defp blob_cid(%{"cid" => cid}) when is_binary(cid), do: cid
  defp blob_cid(_), do: nil

  defp iso(%DateTime{} = dt), do: Syntax.format_datetime(dt)
  defp iso(_), do: nil

  defp compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()

  def viewer_block_exists?(did, state) do
    case state.profile_viewers[did] do
      nil ->
        false

      v ->
        not is_nil(v.blocking) or not is_nil(v.blocked_by) or not is_nil(v.blocking_by_list) or
          not is_nil(v.blocked_by_list)
    end
  end

  def viewer_mute_exists?(did, state) do
    case state.profile_viewers[did] do
      nil -> false
      v -> v.muted or not is_nil(v.muted_by_list)
    end
  end

  def actor_takendown?(did, state) do
    case state.actors[did] do
      %{takedown_ref: ref} when is_binary(ref) -> not state.ctx.include_takedowns
      _ -> false
    end
  end

  def actor_no_hosted?(did, state) do
    case state.actors[did] do
      %{exists: false} -> true
      %{upstream_status: s} when s in ["deactivated", "deleted", "takendown", "suspended"] -> true
      _ -> false
    end
  end

  # ------------------------------------------------------------- labels

  defp labels_for(subject, state), do: Enum.map(state.labels[subject] || [], &label_view/1)

  defp label_view(%{src: src, uri: uri, cid: cid, val: val, cts: cts, exp: exp}) do
    compact(%{
      "src" => src,
      "uri" => uri,
      "cid" => cid,
      "val" => val,
      "cts" => iso(cts),
      "exp" => iso(exp)
    })
  end

  @doc "Upstream selfLabels: `com.atproto.label.defs#selfLabels` inside a record become labels by its author."
  def self_labels(uri, cid, record) do
    case record && record["labels"] do
      %{"$type" => "com.atproto.label.defs#selfLabels", "values" => values}
      when is_list(values) ->
        src = Hydration.did_of(uri)
        cts = record["createdAt"] || "1970-01-01T00:00:00.000Z"

        for %{"val" => val} <- values,
            do: %{"src" => src, "uri" => uri, "cid" => cid, "val" => val, "cts" => cts}

      _ ->
        []
    end
  end

  # ----------------------------------------------------------- profiles

  def profile_basic(did, state) do
    case state.actors[did] do
      nil ->
        nil

      actor ->
        profile_uri = "at://#{did}/app.bsky.actor.profile/self"
        profile = actor.profile

        labels =
          labels_for(did, state) ++
            labels_for(profile_uri, state) ++ self_labels(profile_uri, actor.profile_cid, profile)

        associated =
          compact(%{
            "labeler" => if(actor.is_labeler, do: true),
            "chat" =>
              if(actor.allow_incoming_chats, do: %{"allowIncoming" => actor.allow_incoming_chats}),
            "activitySubscription" => %{
              "allowSubscriptions" => actor.allow_activity_subscriptions
            }
          })

        compact(%{
          "did" => did,
          "handle" => actor.handle || @invalid_handle,
          "displayName" => profile && profile["displayName"],
          "pronouns" => profile && profile["pronouns"],
          "avatar" => avatar(did, profile),
          "associated" => if(associated == %{}, do: nil, else: associated),
          "viewer" => profile_viewer(did, state),
          "labels" => labels,
          "createdAt" => iso(actor.created_at),
          "verification" => verification(did, state),
          "status" => status(did, state)
        })
    end
  end

  defp avatar(did, %{"avatar" => avatar}) when is_map(avatar) do
    case blob_cid(avatar) do
      nil -> nil
      cid -> img("avatar", did, cid)
    end
  end

  defp avatar(_, _), do: nil

  def profile(did, state) do
    case profile_basic(did, state) do
      nil ->
        nil

      basic ->
        actor = state.actors[did]

        Map.merge(
          basic,
          compact(%{
            "description" => actor.profile && actor.profile["description"],
            "indexedAt" => iso(actor.profile_indexed_at || actor.indexed_at)
          })
        )
    end
  end

  def profile_detailed(did, state) do
    case profile(did, state) do
      nil ->
        nil

      base ->
        actor = state.actors[did]

        aggs =
          state.profile_aggs[did] ||
            %{followers: 0, follows: 0, posts: 0, lists: 0, feeds: 0, starter_packs: 0}

        profile = actor.profile
        banner = profile && profile["banner"] && blob_cid(profile["banner"])
        known = known_followers(did, state)

        viewer =
          case base["viewer"] do
            nil -> nil
            v -> compact(Map.put(v, "knownFollowers", known))
          end

        base
        |> Map.merge(
          compact(%{
            "banner" => banner && img("banner", did, banner),
            "followersCount" => aggs.followers,
            "followsCount" => aggs.follows,
            "postsCount" => aggs.posts,
            "associated" =>
              compact(%{
                "lists" => aggs.lists,
                "feedgens" => aggs.feeds,
                "starterPacks" => aggs.starter_packs,
                "labeler" => actor.is_labeler,
                "chat" =>
                  if(actor.allow_incoming_chats,
                    do: %{"allowIncoming" => actor.allow_incoming_chats}
                  ),
                "activitySubscription" => %{
                  "allowSubscriptions" => actor.allow_activity_subscriptions
                }
              }),
            "pinnedPost" => pinned_post(profile),
            "website" => website(profile)
          })
        )
        |> then(&if(viewer, do: Map.put(&1, "viewer", viewer), else: &1))
    end
  end

  defp pinned_post(%{"pinnedPost" => %{"uri" => uri, "cid" => cid}})
       when is_binary(uri) and is_binary(cid), do: %{"uri" => uri, "cid" => cid}

  defp pinned_post(_), do: nil

  defp website(%{"website" => "https://" <> _ = w}), do: w
  defp website(_), do: nil

  def profile_viewer(did, state) do
    case state.profile_viewers[did] do
      nil ->
        nil

      v ->
        blocked_by_uri = v.blocked_by || v.blocked_by_list
        blocking_uri = v.blocking || v.blocking_by_list
        block = not is_nil(blocked_by_uri) or not is_nil(blocking_uri)

        compact(%{
          "muted" => v.muted or not is_nil(v.muted_by_list),
          "mutedByList" => v.muted_by_list && list_basic(v.muted_by_list, state),
          "blockedBy" => not is_nil(blocked_by_uri),
          "blocking" => blocking_uri,
          "blockingByList" => v.blocking_by_list && list_basic(v.blocking_by_list, state),
          "following" => if(v.following && not block, do: v.following),
          "followedBy" => if(v.followed_by && not block, do: v.followed_by)
        })
    end
  end

  def blocked_profile_viewer(did, state) do
    case state.profile_viewers[did] do
      nil ->
        nil

      v ->
        compact(%{
          "blockedBy" => not is_nil(v.blocked_by || v.blocked_by_list),
          "blocking" => v.blocking || v.blocking_by_list
        })
    end
  end

  defp known_followers(did, state) do
    case state.known_followers[did] do
      nil ->
        nil

      %{count: count, followers: followers} ->
        views =
          followers
          |> Enum.reject(
            &(viewer_block_exists?(&1, state) or Hydration.block_between?(state, did, &1) or
                actor_no_hosted?(&1, state))
          )
          |> Enum.map(&profile_basic(&1, state))
          |> Enum.reject(&is_nil/1)

        %{"count" => count, "followers" => views}
    end
  end

  defp verification(did, state) do
    actor = state.actors[did]

    if is_nil(actor) or is_nil(actor.handle) or actor.handle == @invalid_handle do
      nil
    else
      views =
        for v <- actor.verifications do
          issuer = state.actors[v.creator]

          valid =
            v.display_name != "" and
              v.display_name == (actor.profile && actor.profile["displayName"]) and
              v.handle == actor.handle

          compact(%{
            "issuer" => v.creator,
            "issuerDisplayName" => issuer && issuer.profile && issuer.profile["displayName"],
            "issuerHandle" => issuer && issuer.handle,
            "uri" => v.uri,
            "isValid" => valid,
            "createdAt" => iso(v.created_at)
          })
        end

      verified_status =
        cond do
          views == [] -> "none"
          Enum.any?(views, & &1["isValid"]) -> "valid"
          true -> "invalid"
        end

      trusted = if actor.trusted_verifier, do: "valid", else: "none"

      if views == [] and verified_status == "none" and trusted == "none",
        do: nil,
        else: %{
          "verifications" => views,
          "verifiedStatus" => verified_status,
          "trustedVerifierStatus" => trusted
        }
    end
  end

  defp status(did, state) do
    case state.actors[did] do
      %{status: %{status: status, expires_at: expires, record: _}} = _ ->
        %{"status" => status, "expiresAt" => iso(expires)}

      %{status: %{status: status, expires_at: expires}} ->
        active = is_nil(expires) or DateTime.compare(expires, DateTime.utc_now()) == :gt
        compact(%{"status" => status, "expiresAt" => iso(expires), "isActive" => active})

      _ ->
        nil
    end
  end

  # -------------------------------------------------------------- posts

  def post(uri, state, depth \\ 0) do
    with %{} = post <- state.posts[uri],
         author_did = post.creator,
         %{} = author <- profile_basic(author_did, state),
         false <- post.takedown_ref != nil and not state.ctx.include_takedowns do
      aggs = state.post_aggs[uri] || %{likes: 0, replies: 0, reposts: 0, quotes: 0, bookmarks: 0}
      viewer = state.post_viewers[uri]
      record = post.record
      labels = labels_for(uri, state) ++ self_labels(uri, post.cid, record)
      threadgate_uri = Hydration.gate_uri(uri, "app.bsky.feed.threadgate")

      # No `$type`: `#postView` only ever appears where the lexicon already says
      # what it is (a typed array, or a field of `#threadViewPost`), and
      # upstream leaves it out there. The union members that genuinely need
      # discriminating — `#notFoundPost`, `#blockedPost`, `#threadViewPost` —
      # carry theirs.
      compact(%{
        "uri" => uri,
        "cid" => post.cid,
        "author" => author,
        "record" => record,
        "embed" =>
          if(depth < 2 and record["embed"], do: embed(uri, record["embed"], state, depth + 1)),
        "bookmarkCount" => aggs.bookmarks,
        "replyCount" => aggs.replies,
        "repostCount" => aggs.reposts,
        "likeCount" => aggs.likes,
        "quoteCount" => aggs.quotes,
        "indexedAt" => iso(post.indexed_at),
        "viewer" =>
          if viewer do
            compact(%{
              "repost" => viewer.repost,
              "like" => viewer.like,
              "bookmarked" => viewer.bookmarked,
              "threadMuted" => viewer.thread_muted,
              "replyDisabled" => user_reply_disabled(uri, state),
              "embeddingDisabled" => user_post_embedding_disabled(uri, state),
              "pinned" => viewer_pinned(uri, state, author_did)
            })
          end,
        "labels" => labels,
        "threadgate" => if(is_nil(record["reply"]), do: threadgate(threadgate_uri, state))
      })
    else
      _ -> nil
    end
  end

  def threadgate(gate_uri, state) do
    case state.threadgates[gate_uri] do
      %{record: record, cid: cid} ->
        lists =
          for %{"$type" => "app.bsky.feed.threadgate#listRule", "list" => l} <-
                record["allow"] || [],
              v = list_basic(l, state),
              do: v

        %{"uri" => gate_uri, "cid" => cid, "record" => record, "lists" => lists}

      _ ->
        nil
    end
  end

  def user_reply_disabled(uri, state) do
    post = state.posts[uri]

    cond do
      post && post.violates_thread_gate ->
        true

      true ->
        root_uri = (post && get_in(post.record, ["reply", "root", "uri"])) || uri
        gate = state.threadgates[Hydration.gate_uri(root_uri, "app.bsky.feed.threadgate")]
        viewer = state.ctx.viewer

        if is_nil(gate) or is_nil(viewer) do
          nil
        else
          root_record = state.posts[root_uri] && state.posts[root_uri].record
          owner = Hydration.did_of(root_uri)
          parsed = ThreadGates.parse(viewer, owner, root_record, gate.record)
          pv = state.profile_viewers[owner]

          cond do
            parsed[:can_reply] ->
              false

            parsed[:allow_follower] && pv && pv.following ->
              false

            parsed[:allow_following] && pv && pv.followed_by ->
              false

            Enum.any?(
              parsed[:allow_list_uris] || [],
              &(get_in(state.list_viewers, [&1, :viewer_in_list]) != nil)
            ) ->
              false

            true ->
              true
          end
        end
    end
  end

  def user_post_embedding_disabled(uri, state) do
    case state.posts[uri] do
      nil ->
        true

      _ ->
        gate = state.postgates[Hydration.gate_uri(uri, "app.bsky.feed.postgate")]
        not ThreadGates.can_embed?(gate && gate.record, state.ctx.viewer, Hydration.did_of(uri))
    end
  end

  defp viewer_pinned(uri, state, author_did) do
    if state.ctx.viewer && state.ctx.viewer == author_did do
      case state.actors[author_did] do
        %{profile: %{"pinnedPost" => %{"uri" => pinned}}} -> pinned == uri
        _ -> nil
      end
    end
  end

  def feed_view_post(%{post: post_uri} = item, state) do
    post_info = state.posts[post_uri]

    reason =
      cond do
        item[:author_pinned] ->
          {:ok, %{"$type" => "app.bsky.feed.defs#reasonPin"}}

        item[:repost] ->
          case state.reposts[item.repost] do
            nil ->
              :skip

            repost ->
              if get_in(repost.record, ["subject", "uri"]) != post_uri do
                :skip
              else
                case reason_repost(item.repost, repost, state) do
                  nil -> :skip
                  r -> {:ok, r}
                end
              end
          end

        true ->
          {:ok, nil}
      end

    with {:ok, reason} <- reason,
         %{} = post <- post(post_uri, state) do
      reply = if post_info && not post_info.violates_thread_gate, do: reply_ref(post_uri, state)

      compact(%{
        "post" => post,
        "reason" => reason,
        "reply" => reply
      })
    else
      _ -> nil
    end
  end

  def reason_repost(uri, repost, state) do
    case profile_basic(repost.creator, state) do
      nil ->
        nil

      by ->
        %{
          "$type" => "app.bsky.feed.defs#reasonRepost",
          "by" => by,
          "uri" => uri,
          "cid" => repost.cid,
          "indexedAt" => iso(repost.indexed_at)
        }
    end
  end

  def reply_ref(uri, state) do
    record = state.posts[uri] && state.posts[uri].record

    case record && record["reply"] do
      %{"root" => %{"uri" => root_uri}, "parent" => %{"uri" => parent_uri}} ->
        root = maybe_post(root_uri, state)
        parent = maybe_post(parent_uri, state)
        child_blocks = state.post_blocks[uri] || %{}
        parent_blocks = state.post_blocks[parent_uri] || %{}

        parent =
          if post_view?(parent) and child_blocks[:parent] == true,
            do: blocked_post(parent_uri, parent["author"]["did"], state),
            else: parent

        root =
          if post_view?(root) and (child_blocks[:root] == true or parent_blocks[:root] == true),
            do: blocked_post(root_uri, root["author"]["did"], state),
            else: root

        grandparent =
          if post_view?(parent) do
            case get_in(parent, ["record", "reply", "parent", "uri"]) do
              nil -> nil
              gp_uri -> profile_basic(Hydration.did_of(gp_uri), state)
            end
          end

        # `#replyRef.root` and `.parent` are a union of `#postView`,
        # `#notFoundPost` and `#blockedPost`, and a union member has to say what
        # it is. Everywhere else a post view sits in a slot the lexicon has
        # already typed, and upstream leaves `$type` out there.
        compact(%{
          "root" => tag_post_view(root),
          "parent" => tag_post_view(parent),
          "grandparentAuthor" => grandparent
        })

      _ ->
        nil
    end
  end

  # A `#replyRef` slot holds a post view, a `#notFoundPost` or a `#blockedPost`.
  # The latter two say so in `$type`; a post view is the one without.
  defp post_view?(%{"$type" => _}), do: false
  defp post_view?(%{"uri" => _, "author" => _}), do: true
  defp post_view?(_), do: false

  defp tag_post_view(view) do
    if post_view?(view), do: Map.put(view, "$type", "app.bsky.feed.defs#postView"), else: view
  end

  def maybe_post(uri, state) do
    case post(uri, state) do
      nil ->
        not_found_post(uri)

      view ->
        if viewer_block_exists?(view["author"]["did"], state),
          do: blocked_post(uri, view["author"]["did"], state),
          else: view
    end
  end

  def blocked_post(uri, author_did, state) do
    %{
      "$type" => "app.bsky.feed.defs#blockedPost",
      "uri" => uri,
      "blocked" => true,
      "author" =>
        compact(%{"did" => author_did, "viewer" => blocked_profile_viewer(author_did, state)})
    }
  end

  def not_found_post(uri),
    do: %{"$type" => "app.bsky.feed.defs#notFoundPost", "uri" => uri, "notFound" => true}

  # ------------------------------------------------------------- embeds

  def embed(post_uri, embed, state, depth) do
    did = Hydration.did_of(post_uri)

    case embed["$type"] do
      "app.bsky.embed.images" -> images_embed(did, embed)
      "app.bsky.embed.video" -> video_embed(did, embed)
      "app.bsky.embed.external" -> external_embed(did, embed)
      "app.bsky.embed.record" -> record_embed(post_uri, embed, state, depth, true)
      "app.bsky.embed.recordWithMedia" -> record_with_media_embed(post_uri, embed, state, depth)
      _ -> nil
    end
  end

  def images_embed(did, %{"images" => images}) do
    views =
      for img <- images || [], cid = blob_cid(img["image"]) do
        compact(%{
          "thumb" => img("feed_thumbnail", did, cid),
          "fullsize" => img("feed_fullsize", did, cid),
          "alt" => img["alt"] || "",
          "aspectRatio" => img["aspectRatio"]
        })
      end

    %{"$type" => "app.bsky.embed.images#view", "images" => views}
  end

  def video_embed(did, %{"video" => video} = embed) do
    cid = blob_cid(video)

    compact(%{
      "$type" => "app.bsky.embed.video#view",
      "cid" => cid,
      # DESIGN §15: no video CDN; the playlist points at the raw blob on the PDS-facing image host
      "playlist" => "#{Config.public_url()}/video/#{did}/#{cid}/playlist.m3u8",
      "thumbnail" => nil,
      "alt" => embed["alt"],
      "aspectRatio" => embed["aspectRatio"]
    })
  end

  def external_embed(did, %{"external" => ext}) do
    thumb = ext["thumb"] && blob_cid(ext["thumb"])

    %{
      "$type" => "app.bsky.embed.external#view",
      "external" =>
        compact(%{
          "uri" => ext["uri"],
          "title" => ext["title"] || "",
          "description" => ext["description"] || "",
          "thumb" => thumb && img("feed_thumbnail", did, thumb)
        })
    }
  end

  def record_embed(post_uri, %{"record" => %{"uri" => uri}}, state, depth, typed?) do
    embedded_did = Hydration.did_of(uri)
    post = state.posts[post_uri]
    blocks = state.post_blocks[post_uri] || %{}

    inner =
      cond do
        viewer_block_exists?(embedded_did, state) or blocks[:embed] ->
          embed_blocked(uri, state)

        post && post.violates_embedding_rules ->
          embed_detached(uri)

        true ->
          case Hydration.collection_of(uri) do
            "app.bsky.feed.post" ->
              case embed_post_view(uri, state, depth) do
                nil ->
                  embed_not_found(uri)

                view ->
                  gate = state.postgates[Hydration.gate_uri(uri, "app.bsky.feed.postgate")]

                  if gate && post_uri in (get_in(gate.record, ["detachedEmbeddingUris"]) || []),
                    do: embed_detached(uri),
                    else: view
              end

            "app.bsky.feed.generator" ->
              (feed_generator(uri, state) &&
                 Map.put(feed_generator(uri, state), "$type", "app.bsky.feed.defs#generatorView")) ||
                embed_not_found(uri)

            "app.bsky.graph.list" ->
              (list(uri, state) &&
                 Map.put(list(uri, state), "$type", "app.bsky.graph.defs#listView")) ||
                embed_not_found(uri)

            "app.bsky.labeler.service" ->
              (labeler(embedded_did, state) &&
                 Map.put(
                   labeler(embedded_did, state),
                   "$type",
                   "app.bsky.labeler.defs#labelerView"
                 )) || embed_not_found(uri)

            _ ->
              embed_not_found(uri)
          end
      end

    if typed?,
      do: %{"$type" => "app.bsky.embed.record#view", "record" => inner},
      else: %{"record" => inner}
  end

  defp embed_not_found(uri),
    do: %{"$type" => "app.bsky.embed.record#viewNotFound", "uri" => uri, "notFound" => true}

  defp embed_detached(uri),
    do: %{"$type" => "app.bsky.embed.record#viewDetached", "uri" => uri, "detached" => true}

  defp embed_blocked(uri, state) do
    creator = Hydration.did_of(uri)

    %{
      "$type" => "app.bsky.embed.record#viewBlocked",
      "uri" => uri,
      "blocked" => true,
      "author" => compact(%{"did" => creator, "viewer" => blocked_profile_viewer(creator, state)})
    }
  end

  defp embed_post_view(uri, state, depth) do
    case post(uri, state, depth) do
      nil ->
        nil

      view ->
        compact(%{
          "$type" => "app.bsky.embed.record#viewRecord",
          "uri" => view["uri"],
          "cid" => view["cid"],
          "author" => view["author"],
          "value" => view["record"],
          "labels" => view["labels"],
          "likeCount" => view["likeCount"],
          "replyCount" => view["replyCount"],
          "repostCount" => view["repostCount"],
          "quoteCount" => view["quoteCount"],
          "indexedAt" => view["indexedAt"],
          "embeds" =>
            if(depth > 1, do: nil, else: if(view["embed"], do: [view["embed"]], else: []))
        })
    end
  end

  def record_with_media_embed(post_uri, %{"record" => record, "media" => media}, state, depth) do
    did = Hydration.did_of(post_uri)

    media_view =
      case media["$type"] do
        "app.bsky.embed.images" -> images_embed(did, media)
        "app.bsky.embed.video" -> video_embed(did, media)
        "app.bsky.embed.external" -> external_embed(did, media)
        _ -> nil
      end

    if media_view do
      %{
        "$type" => "app.bsky.embed.recordWithMedia#view",
        "media" => media_view,
        "record" => record_embed(post_uri, record, state, depth, false)
      }
    end
  end

  # -------------------------------------------------------------- lists

  def list_basic(uri, state) do
    case state.lists[uri] do
      nil ->
        nil

      %{row: row, record: record} ->
        creator = row.creator
        avatar = record["avatar"] && blob_cid(record["avatar"])
        viewer = state.list_viewers[uri]

        compact(%{
          "uri" => uri,
          "cid" => row.cid,
          "name" => record["name"],
          "purpose" => record["purpose"],
          "avatar" => avatar && img("avatar", creator, avatar),
          "listItemCount" => state.list_aggs[uri] || 0,
          "labels" => labels_for(uri, state),
          "viewer" => viewer && compact(%{"muted" => viewer.muted, "blocked" => viewer.blocked}),
          "indexedAt" => iso(row.indexed_at)
        })
    end
  end

  def list(uri, state) do
    with %{row: row, record: record} <- state.lists[uri],
         %{} = basic <- list_basic(uri, state),
         %{} = creator <- profile(row.creator, state) do
      Map.merge(
        basic,
        compact(%{
          "creator" => creator,
          "description" => record["description"],
          "descriptionFacets" => record["descriptionFacets"]
        })
      )
    else
      _ -> nil
    end
  end

  # ------------------------------------------------------- feed generators

  def feed_generator(uri, state) do
    with %{row: row, record: record} <- state.feed_gens[uri],
         %{} = creator <- profile(row.creator, state) do
      aggs = state.feed_gen_aggs[uri] || %{likes: 0, viewer_like: nil}
      avatar = record["avatar"] && blob_cid(record["avatar"])

      compact(%{
        "uri" => uri,
        "cid" => row.cid,
        "did" => record["did"],
        "creator" => creator,
        "displayName" => record["displayName"],
        "description" => record["description"],
        "descriptionFacets" => record["descriptionFacets"],
        "avatar" => avatar && img("avatar", row.creator, avatar),
        "likeCount" => aggs.likes,
        "acceptsInteractions" => record["acceptsInteractions"],
        "labels" => labels_for(uri, state),
        "viewer" => if(state.ctx.viewer, do: compact(%{"like" => aggs.viewer_like})),
        "contentMode" => record["contentMode"],
        "indexedAt" => iso(row.indexed_at)
      })
    else
      _ -> nil
    end
  end

  # ------------------------------------------------------------ labelers

  def labeler(did, state) do
    with %{row: row, record: _record, likes: likes} <- state.labelers[did],
         %{} = creator <- profile(did, state) do
      uri = "at://#{did}/app.bsky.labeler.service/self"

      compact(%{
        "uri" => uri,
        "cid" => row.cid,
        "creator" => creator,
        "likeCount" => likes,
        "viewer" => if(state.ctx.viewer, do: %{}),
        "indexedAt" => iso(row.indexed_at),
        "labels" => labels_for(uri, state)
      })
    else
      _ -> nil
    end
  end

  def labeler_detailed(did, state) do
    with %{record: record} <- state.labelers[did],
         %{} = view <- labeler(did, state) do
      Map.merge(
        view,
        compact(%{
          "policies" => record["policies"],
          "reasonTypes" => record["reasonTypes"],
          "subjectTypes" => record["subjectTypes"],
          "subjectCollections" => record["subjectCollections"]
        })
      )
    else
      _ -> nil
    end
  end

  # ------------------------------------------------------------- threads

  @doc "Upstream `thread`: the anchor with parents up to `height` and replies down to `depth`."
  def thread(anchor, uris, state, height, depth) do
    post_info = state.posts[anchor]
    post = post(anchor, state)

    cond do
      is_nil(post_info) or is_nil(post) ->
        not_found_post(anchor)

      viewer_block_exists?(post["author"]["did"], state) ->
        blocked_post(anchor, post["author"]["did"], state)

      true ->
        children =
          Enum.reduce(uris, {MapSet.new([anchor]), %{}}, fn uri, {seen, acc} ->
            parent =
              state.posts[uri] && get_in(state.posts[uri].record, ["reply", "parent", "uri"])

            if is_nil(parent) or MapSet.member?(seen, uri),
              do: {seen, acc},
              else: {MapSet.put(seen, uri), Map.update(acc, parent, [uri], &(&1 ++ [uri]))}
          end)
          |> elem(1)

        root_uri = get_in(post_info.record, ["reply", "root", "uri"]) || anchor

        compact(%{
          "$type" => "app.bsky.feed.defs#threadViewPost",
          "post" => post,
          "parent" =>
            if(not post_info.violates_thread_gate,
              do: thread_parent(anchor, root_uri, state, height)
            ),
          "replies" =>
            if(not post_info.violates_thread_gate,
              do: thread_replies(anchor, root_uri, children, state, depth)
            ),
          "threadContext" =>
            compact(%{"rootAuthorLike" => get_in(state.thread_contexts, [anchor, :like])})
        })
    end
  end

  defp thread_parent(_child, _root, _state, height) when height < 1, do: nil

  defp thread_parent(child_uri, root_uri, state, height) do
    parent_uri =
      state.posts[child_uri] && get_in(state.posts[child_uri].record, ["reply", "parent", "uri"])

    cond do
      is_nil(parent_uri) ->
        nil

      get_in(state.post_blocks, [child_uri, :parent]) ->
        blocked_post(parent_uri, Hydration.did_of(parent_uri), state)

      true ->
        post = post(parent_uri, state)
        info = state.posts[parent_uri]

        cond do
          is_nil(post) or is_nil(info) ->
            not_found_post(parent_uri)

          root_uri != (get_in(info.record, ["reply", "root", "uri"]) || parent_uri) ->
            nil

          viewer_block_exists?(post["author"]["did"], state) ->
            blocked_post(parent_uri, post["author"]["did"], state)

          true ->
            compact(%{
              "$type" => "app.bsky.feed.defs#threadViewPost",
              "post" => post,
              "parent" => thread_parent(parent_uri, root_uri, state, height - 1),
              "threadContext" =>
                compact(%{"rootAuthorLike" => get_in(state.thread_contexts, [parent_uri, :like])})
            })
        end
    end
  end

  defp thread_replies(_parent, _root, _children, _state, depth) when depth < 1, do: nil

  defp thread_replies(parent_uri, root_uri, children, state, depth) do
    for uri <- children[parent_uri] || [],
        info = state.posts[uri],
        not info.violates_thread_gate,
        not get_in(state.post_blocks, [uri, :parent]),
        post = post(uri, state),
        not is_nil(post),
        (get_in(info.record, ["reply", "root", "uri"]) || uri) == root_uri do
      if viewer_block_exists?(post["author"]["did"], state) do
        blocked_post(uri, post["author"]["did"], state)
      else
        compact(%{
          "$type" => "app.bsky.feed.defs#threadViewPost",
          "post" => post,
          "replies" => thread_replies(uri, root_uri, children, state, depth - 1),
          "threadContext" =>
            compact(%{"rootAuthorLike" => get_in(state.thread_contexts, [uri, :like])})
        })
      end
    end
  end

  # ------------------------------------------------------- feed item filters

  @doc "Upstream feedItemBlocksAndMutes."
  def feed_item_blocks_and_mutes(%{post: post_uri} = item, state) do
    author = Hydration.did_of(post_uri)
    originator = if item[:repost], do: Hydration.did_of(item.repost), else: author
    post = state.posts[post_uri]
    parent_uri = post && get_in(post.record, ["reply", "parent", "uri"])
    root_uri = post && get_in(post.record, ["reply", "root", "uri"])
    blocks = state.post_blocks[post_uri] || %{}

    %{
      author_blocked: viewer_block_exists?(author, state),
      author_muted: viewer_mute_exists?(author, state),
      originator_blocked: viewer_block_exists?(originator, state),
      originator_muted: viewer_mute_exists?(originator, state),
      ancestor_author_blocked:
        blocks[:parent] == true or blocks[:root] == true or
          (parent_uri != nil and viewer_block_exists?(Hydration.did_of(parent_uri), state)) or
          (root_uri != nil and viewer_block_exists?(Hydration.did_of(root_uri), state))
    }
  end

  # ------------------------------------------------------- notifications

  def notification(notif, last_seen, state) do
    uri = notif.record_uri
    author = profile(notif.author, state)
    collection = Hydration.collection_of(uri)

    info =
      case collection do
        "app.bsky.feed.post" ->
          state.posts[uri]

        "app.bsky.feed.like" ->
          state.likes[uri]

        "app.bsky.feed.repost" ->
          state.reposts[uri]

        "app.bsky.graph.follow" ->
          state.follows[uri]

        "app.bsky.graph.verification" ->
          state.verifications[uri] ||
            %{
              cid: notif.record_cid,
              record: %{"$type" => "app.bsky.notification.defs#recordDeleted"}
            }

        "app.bsky.actor.profile" ->
          case state.actors[notif.author] do
            %{profile: p, profile_cid: c} when is_map(p) -> %{cid: c, record: p}
            _ -> nil
          end

        _ ->
          nil
      end

    if author && info do
      indexed_at = iso(notif.sort_at)

      compact(%{
        "uri" => uri,
        "cid" => info.cid,
        "author" => author,
        "reason" => notif.reason,
        "reasonSubject" => notif.reason_subject,
        "record" => info.record,
        "isRead" =>
          if(last_seen, do: DateTime.compare(last_seen, notif.sort_at) == :gt, else: true),
        "indexedAt" => indexed_at,
        "labels" => labels_for(uri, state) ++ self_labels(uri, info.cid, info.record)
      })
    end
  end
end
