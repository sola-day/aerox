# The plugins whose rules are a row insert/delete with at most one
# aggregate or notification (upstream plugins/{like,repost,follow,block,
# list,list-item,list-block,profile,feed-generator,labeler,starter-pack,
# thread-gate,post-gate,verification,status,*-declaration}.ts).

defmodule Aerox.AppView.Plugins.Like do
  @moduledoc false
  use Aerox.AppView.Plugin
  alias Aerox.AppView.Plugin

  def collection, do: "app.bsky.feed.like"

  def insert(uri, cid, record, indexed_at) do
    insert_row(Schema.Like, %{
      uri: uri,
      cid: cid,
      creator: uri_did(uri),
      subject: record["subject"]["uri"],
      subject_cid: cid_string(record["subject"]["cid"]),
      via: get_in(record, ["via", "uri"]),
      via_cid: cid_string(get_in(record, ["via", "cid"])),
      created_at: created_at(record["createdAt"]),
      indexed_at: indexed_at
    })
  end

  def find_duplicate(uri, record) do
    Repo.one(
      from(l in Schema.Like,
        where: l.creator == ^uri_did(uri) and l.subject == ^record["subject"]["uri"],
        select: l.uri
      )
    )
  end

  def delete(uri), do: delete_rows(Schema.Like, uri: uri)

  def notifs_for_insert(like) do
    subject_did = uri_did(like.subject)

    if subject_did == like.creator do
      []
    else
      via =
        if like.via && uri_did(like.via) != like.creator,
          do: [Plugin.notif(uri_did(like.via), like, "like-via-repost", like.via)],
          else: []

      [Plugin.notif(subject_did, like, "like", like.subject) | via]
    end
  end

  def update_aggregates(like) do
    n = count(from(l in Schema.Like, where: l.subject == ^like.subject))
    Plugin.set_aggregate(Schema.PostAgg, :uri, like.subject, :like_count, n)
  end
end

defmodule Aerox.AppView.Plugins.Repost do
  @moduledoc false
  use Aerox.AppView.Plugin
  alias Aerox.AppView.Plugin

  def collection, do: "app.bsky.feed.repost"

  def insert(uri, cid, record, indexed_at) do
    created = created_at(record["createdAt"])

    row =
      insert_row(Schema.Repost, %{
        uri: uri,
        cid: cid,
        creator: uri_did(uri),
        subject: record["subject"]["uri"],
        subject_cid: cid_string(record["subject"]["cid"]),
        via: get_in(record, ["via", "uri"]),
        via_cid: cid_string(get_in(record, ["via", "cid"])),
        created_at: created,
        indexed_at: indexed_at
      })

    if row do
      insert_row(Schema.FeedItem, %{
        uri: uri,
        cid: cid,
        type: "repost",
        post_uri: row.subject,
        originator_did: row.creator,
        sort_at: min_dt(created, indexed_at)
      })
    end

    row
  end

  def find_duplicate(uri, record) do
    Repo.one(
      from(r in Schema.Repost,
        where: r.creator == ^uri_did(uri) and r.subject == ^record["subject"]["uri"],
        select: r.uri
      )
    )
  end

  def delete(uri) do
    Repo.delete_all(from(f in Schema.FeedItem, where: f.uri == ^uri))
    delete_rows(Schema.Repost, uri: uri)
  end

  def notifs_for_insert(repost) do
    subject_did = uri_did(repost.subject)

    if subject_did == repost.creator do
      []
    else
      via =
        if repost.via && uri_did(repost.via) != repost.creator,
          do: [Plugin.notif(uri_did(repost.via), repost, "repost-via-repost", repost.via)],
          else: []

      [Plugin.notif(subject_did, repost, "repost", repost.subject) | via]
    end
  end

  def update_aggregates(repost) do
    n = count(from(r in Schema.Repost, where: r.subject == ^repost.subject))
    Plugin.set_aggregate(Schema.PostAgg, :uri, repost.subject, :repost_count, n)
  end
end

defmodule Aerox.AppView.Plugins.Follow do
  @moduledoc false
  use Aerox.AppView.Plugin
  alias Aerox.AppView.Plugin

  def collection, do: "app.bsky.graph.follow"

  def insert(uri, cid, record, indexed_at) do
    insert_row(Schema.Follow, %{
      uri: uri,
      cid: cid,
      creator: uri_did(uri),
      subject_did: record["subject"],
      created_at: created_at(record["createdAt"]),
      indexed_at: indexed_at
    })
  end

  def find_duplicate(uri, record) do
    Repo.one(
      from(f in Schema.Follow,
        where: f.creator == ^uri_did(uri) and f.subject_did == ^record["subject"],
        select: f.uri
      )
    )
  end

  def delete(uri), do: delete_rows(Schema.Follow, uri: uri)

  def notifs_for_insert(follow) do
    if follow.subject_did == follow.creator,
      do: [],
      else: [Plugin.notif(follow.subject_did, follow, "follow", nil)]
  end

  def update_aggregates(follow) do
    followers = count(from(f in Schema.Follow, where: f.subject_did == ^follow.subject_did))
    Plugin.set_aggregate(Schema.ProfileAgg, :did, follow.subject_did, :followers_count, followers)
    follows = count(from(f in Schema.Follow, where: f.creator == ^follow.creator))
    Plugin.set_aggregate(Schema.ProfileAgg, :did, follow.creator, :follows_count, follows)
  end
end

defmodule Aerox.AppView.Plugins.Block do
  @moduledoc false
  use Aerox.AppView.Plugin

  def collection, do: "app.bsky.graph.block"

  def insert(uri, cid, record, indexed_at) do
    insert_row(Schema.ActorBlock, %{
      uri: uri,
      cid: cid,
      creator: uri_did(uri),
      subject_did: record["subject"],
      created_at: created_at(record["createdAt"]),
      indexed_at: indexed_at
    })
  end

  def find_duplicate(uri, record) do
    Repo.one(
      from(b in Schema.ActorBlock,
        where: b.creator == ^uri_did(uri) and b.subject_did == ^record["subject"],
        select: b.uri
      )
    )
  end

  def delete(uri), do: delete_rows(Schema.ActorBlock, uri: uri)
end

defmodule Aerox.AppView.Plugins.List do
  @moduledoc false
  use Aerox.AppView.Plugin

  def collection, do: "app.bsky.graph.list"

  def insert(uri, cid, record, indexed_at) do
    insert_row(Schema.List, %{
      uri: uri,
      cid: cid,
      creator: uri_did(uri),
      name: record["name"],
      purpose: record["purpose"],
      description: record["description"],
      description_facets:
        record["descriptionFacets"] && Aerox.ATProto.Data.to_json(record["descriptionFacets"]),
      avatar_cid: record["avatar"] && blob_cid(record["avatar"]),
      created_at: created_at(record["createdAt"]),
      indexed_at: indexed_at
    })
  end

  def delete(uri), do: delete_rows(Schema.List, uri: uri)
end

defmodule Aerox.AppView.Plugins.ListItem do
  @moduledoc false
  use Aerox.AppView.Plugin

  def collection, do: "app.bsky.graph.listitem"

  def insert(uri, cid, record, indexed_at) do
    # upstream: a list item must belong to a list of the same creator
    if uri_did(record["list"]) == uri_did(uri) do
      insert_row(Schema.ListItem, %{
        uri: uri,
        cid: cid,
        creator: uri_did(uri),
        subject_did: record["subject"],
        list_uri: record["list"],
        created_at: created_at(record["createdAt"]),
        indexed_at: indexed_at
      })
    end
  end

  def find_duplicate(_uri, record) do
    Repo.one(
      from(i in Schema.ListItem,
        where: i.list_uri == ^record["list"] and i.subject_did == ^record["subject"],
        select: i.uri
      )
    )
  end

  def delete(uri), do: delete_rows(Schema.ListItem, uri: uri)
end

defmodule Aerox.AppView.Plugins.ListBlock do
  @moduledoc false
  use Aerox.AppView.Plugin

  def collection, do: "app.bsky.graph.listblock"

  def insert(uri, cid, record, indexed_at) do
    insert_row(Schema.ListBlock, %{
      uri: uri,
      cid: cid,
      creator: uri_did(uri),
      subject_uri: record["subject"],
      created_at: created_at(record["createdAt"]),
      indexed_at: indexed_at
    })
  end

  def find_duplicate(uri, record) do
    Repo.one(
      from(b in Schema.ListBlock,
        where: b.creator == ^uri_did(uri) and b.subject_uri == ^record["subject"],
        select: b.uri
      )
    )
  end

  def delete(uri), do: delete_rows(Schema.ListBlock, uri: uri)
end

defmodule Aerox.AppView.Plugins.Profile do
  @moduledoc false
  use Aerox.AppView.Plugin
  alias Aerox.AppView.Plugin

  def collection, do: "app.bsky.actor.profile"

  def insert(uri, cid, record, indexed_at) do
    if uri_rkey(uri) == "self" do
      insert_row(Schema.Profile, %{
        uri: uri,
        cid: cid,
        creator: uri_did(uri),
        display_name: record["displayName"],
        description: record["description"],
        avatar_cid: record["avatar"] && blob_cid(record["avatar"]),
        banner_cid: record["banner"] && blob_cid(record["banner"]),
        joined_via_starter_pack_uri: get_in(record, ["joinedViaStarterPack", "uri"]),
        pinned_post: get_in(record, ["pinnedPost", "uri"]),
        pinned_post_cid: cid_string(get_in(record, ["pinnedPost", "cid"])),
        created_at: record["createdAt"] && created_at(record["createdAt"]),
        indexed_at: indexed_at
      })
    end
  end

  def delete(uri), do: delete_rows(Schema.Profile, uri: uri)

  # starterpack-joined: notify the starter pack's creator
  def notifs_for_insert(%{joined_via_starter_pack_uri: sp} = profile) when is_binary(sp) do
    creator = uri_did(sp)

    if creator && creator != profile.creator,
      do: [
        %{
          did: creator,
          author: profile.creator,
          record_uri: profile.uri,
          record_cid: profile.cid,
          reason: "starterpack-joined",
          reason_subject: sp,
          sort_at: profile.indexed_at
        }
      ],
      else: []
  end

  def notifs_for_insert(_), do: []

  def notifs_for_delete(_deleted, _replaced), do: %{notifs: [], to_delete: []}

  def update_aggregates(_), do: :ok

  @doc false
  def _plugin, do: Plugin
end

defmodule Aerox.AppView.Plugins.FeedGenerator do
  @moduledoc false
  use Aerox.AppView.Plugin

  def collection, do: "app.bsky.feed.generator"

  def insert(uri, cid, record, indexed_at) do
    insert_row(Schema.FeedGenerator, %{
      uri: uri,
      cid: cid,
      creator: uri_did(uri),
      feed_did: record["did"],
      display_name: record["displayName"],
      description: record["description"],
      description_facets:
        record["descriptionFacets"] && Aerox.ATProto.Data.to_json(record["descriptionFacets"]),
      avatar_cid: record["avatar"] && blob_cid(record["avatar"]),
      created_at: created_at(record["createdAt"]),
      indexed_at: indexed_at
    })
  end

  def delete(uri), do: delete_rows(Schema.FeedGenerator, uri: uri)
  def notifs_for_delete(_, _), do: %{notifs: [], to_delete: []}
end

defmodule Aerox.AppView.Plugins.Labeler do
  @moduledoc false
  use Aerox.AppView.Plugin

  def collection, do: "app.bsky.labeler.service"

  def insert(uri, cid, record, indexed_at) do
    if uri_rkey(uri) == "self" do
      insert_row(Schema.Labeler, %{
        uri: uri,
        cid: cid,
        creator: uri_did(uri),
        created_at: created_at(record["createdAt"]),
        indexed_at: indexed_at
      })
    end
  end

  def delete(uri), do: delete_rows(Schema.Labeler, uri: uri)
  def notifs_for_delete(_, _), do: %{notifs: [], to_delete: []}
end

defmodule Aerox.AppView.Plugins.StarterPack do
  @moduledoc false
  use Aerox.AppView.Plugin

  def collection, do: "app.bsky.graph.starterpack"

  def insert(uri, cid, record, indexed_at) do
    insert_row(Schema.StarterPack, %{
      uri: uri,
      cid: cid,
      creator: uri_did(uri),
      name: record["name"],
      created_at: created_at(record["createdAt"]),
      indexed_at: indexed_at
    })
  end

  def delete(uri), do: delete_rows(Schema.StarterPack, uri: uri)
  def notifs_for_delete(_, _), do: %{notifs: [], to_delete: []}
end

defmodule Aerox.AppView.Plugins.ThreadGate do
  @moduledoc false
  use Aerox.AppView.Plugin

  def collection, do: "app.bsky.feed.threadgate"

  def insert(uri, cid, record, indexed_at) do
    post_uri = record["post"]
    # a gate must sit at <post rkey> in the author's own repo
    if uri_did(post_uri) == uri_did(uri) and uri_rkey(post_uri) == uri_rkey(uri) do
      row =
        insert_row(Schema.ThreadGate, %{
          uri: uri,
          cid: cid,
          creator: uri_did(uri),
          post_uri: post_uri,
          created_at: created_at(record["createdAt"]),
          indexed_at: indexed_at
        })

      if row,
        do:
          Repo.update_all(from(p in Schema.Post, where: p.uri == ^post_uri),
            set: [has_thread_gate: true]
          )

      row
    end
  end

  def find_duplicate(_uri, record) do
    Repo.one(from(g in Schema.ThreadGate, where: g.post_uri == ^record["post"], select: g.uri))
  end

  def delete(uri) do
    case delete_rows(Schema.ThreadGate, uri: uri) do
      nil ->
        nil

      row ->
        Repo.update_all(from(p in Schema.Post, where: p.uri == ^row.post_uri),
          set: [has_thread_gate: false]
        )

        row
    end
  end

  def notifs_for_delete(_, _), do: %{notifs: [], to_delete: []}
end

defmodule Aerox.AppView.Plugins.PostGate do
  @moduledoc false
  use Aerox.AppView.Plugin

  def collection, do: "app.bsky.feed.postgate"

  def insert(uri, cid, record, indexed_at) do
    post_uri = record["post"]

    if uri_did(post_uri) == uri_did(uri) and uri_rkey(post_uri) == uri_rkey(uri) do
      row =
        insert_row(Schema.PostGate, %{
          uri: uri,
          cid: cid,
          creator: uri_did(uri),
          post_uri: post_uri,
          created_at: created_at(record["createdAt"]),
          indexed_at: indexed_at
        })

      if row,
        do:
          Repo.update_all(from(p in Schema.Post, where: p.uri == ^post_uri),
            set: [has_post_gate: true]
          )

      row
    end
  end

  def find_duplicate(_uri, record) do
    Repo.one(from(g in Schema.PostGate, where: g.post_uri == ^record["post"], select: g.uri))
  end

  def delete(uri) do
    case delete_rows(Schema.PostGate, uri: uri) do
      nil ->
        nil

      row ->
        Repo.update_all(from(p in Schema.Post, where: p.uri == ^row.post_uri),
          set: [has_post_gate: false]
        )

        row
    end
  end

  def notifs_for_delete(_, _), do: %{notifs: [], to_delete: []}
end

defmodule Aerox.AppView.Plugins.Verification do
  @moduledoc false
  use Aerox.AppView.Plugin
  alias Aerox.AppView.Plugin

  def collection, do: "app.bsky.graph.verification"

  def insert(uri, cid, record, indexed_at) do
    insert_row(Schema.Verification, %{
      uri: uri,
      cid: cid,
      rkey: uri_rkey(uri),
      creator: uri_did(uri),
      subject: record["subject"],
      handle: record["handle"],
      display_name: record["displayName"],
      created_at: created_at(record["createdAt"]),
      indexed_at: indexed_at
    })
  end

  def find_duplicate(uri, record) do
    Repo.one(
      from(v in Schema.Verification,
        where: v.creator == ^uri_did(uri) and v.subject == ^record["subject"],
        select: v.uri
      )
    )
  end

  def delete(uri), do: delete_rows(Schema.Verification, uri: uri)

  def notifs_for_insert(v) do
    if v.subject == v.creator, do: [], else: [Plugin.notif(v.subject, v, "verified", nil)]
  end

  def notifs_for_delete(deleted, replaced_by) do
    if replaced_by,
      do: %{notifs: [], to_delete: []},
      else: %{
        notifs: [Plugin.notif(deleted.subject, deleted, "unverified", nil)],
        to_delete: [deleted.uri]
      }
  end
end

defmodule Aerox.AppView.Plugins.Status do
  @moduledoc false
  use Aerox.AppView.Plugin

  def collection, do: "app.bsky.actor.status"

  def insert(uri, cid, record, indexed_at) do
    if uri_rkey(uri) == "self" do
      expires =
        case record["durationMinutes"] do
          n when is_integer(n) -> DateTime.add(created_at(record["createdAt"]), n * 60, :second)
          _ -> nil
        end

      Repo.insert_all(
        Schema.ActorStatus,
        [
          %{
            did: uri_did(uri),
            uri: uri,
            cid: cid,
            status: record["status"],
            expires_at: expires,
            created_at: created_at(record["createdAt"]),
            indexed_at: indexed_at
          }
        ],
        on_conflict: {:replace_all_except, [:did]},
        conflict_target: :did
      )

      %{uri: uri, cid: cid, creator: uri_did(uri)}
    end
  end

  def delete(uri), do: delete_rows(Schema.ActorStatus, uri: uri)
  def notifs_for_delete(_, _), do: %{notifs: [], to_delete: []}
end

# The three declarations are indexed in `record` only (upstream placeholder
# plugins); hydration reads them from there.
for {mod, nsid} <- [
      {Aerox.AppView.Plugins.ChatDeclaration, "chat.bsky.actor.declaration"},
      {Aerox.AppView.Plugins.NotifDeclaration, "app.bsky.notification.declaration"},
      {Aerox.AppView.Plugins.GermDeclaration, "app.bsky.germ.declaration"}
    ] do
  defmodule mod do
    @moduledoc false
    use Aerox.AppView.Plugin
    @nsid nsid

    def collection, do: @nsid

    def insert(uri, cid, _record, _indexed_at),
      do: if(uri_rkey(uri) == "self", do: %{uri: uri, cid: cid, creator: uri_did(uri)})

    def delete(uri), do: if(uri_rkey(uri) == "self", do: %{uri: uri})
    def notifs_for_delete(_, _), do: %{notifs: [], to_delete: []}
  end
end
