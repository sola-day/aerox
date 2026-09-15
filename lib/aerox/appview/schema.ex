# The AppView's Ecto schemas, one per table of the `appview` migration
# (DESIGN §15.2). Kept together: they are plain row shapes with no behaviour.

defmodule Aerox.AppView.Schema.Actor do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:did, :string, autogenerate: false}
  schema "actor" do
    field :handle, :string
    field :indexed_at, :utc_datetime_usec
    field :takedown_ref, :string
    field :upstream_status, :string
    field :trusted_verifier, :boolean, default: false
  end
end

defmodule Aerox.AppView.Schema.ActorSync do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:did, :string, autogenerate: false}
  schema "actor_sync" do
    field :commit_cid, :string
    field :repo_rev, :string
    field :data_cid, :string
    field :status, :string, default: "synchronized"
    field :updated_at, :utc_datetime_usec
  end
end

defmodule Aerox.AppView.Schema.ActorSyncPending do
  @moduledoc false
  use Ecto.Schema

  schema "actor_sync_pending" do
    field :did, :string
    field :seq, :integer
    field :type, :string
    field :rev, :string
    field :body, :binary
    field :inserted_at, :utc_datetime_usec
  end
end

defmodule Aerox.AppView.Schema.ActorState do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:did, :string, autogenerate: false}
  schema "actor_state" do
    field :last_seen_notifs, :utc_datetime_usec
    field :priority_notifs, :boolean, default: false
    field :last_seen_priority_notifs, :utc_datetime_usec
  end
end

defmodule Aerox.AppView.Schema.Record do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:uri, :string, autogenerate: false}
  schema "record" do
    field :cid, :string
    field :did, :string
    field :json, :map
    field :indexed_at, :utc_datetime_usec
    field :takedown_ref, :string
    field :tags, {:array, :string}
  end
end

defmodule Aerox.AppView.Schema.DuplicateRecord do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:uri, :string, autogenerate: false}
  schema "duplicate_record" do
    field :cid, :string
    field :duplicate_of, :string
    field :indexed_at, :utc_datetime_usec
  end
end

defmodule Aerox.AppView.Schema.Post do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:uri, :string, autogenerate: false}
  schema "post" do
    field :cid, :string
    field :creator, :string
    field :text, :string
    field :reply_root, :string
    field :reply_root_cid, :string
    field :reply_parent, :string
    field :reply_parent_cid, :string
    field :langs, {:array, :string}
    field :tags, {:array, :string}
    field :invalid_reply_root, :boolean
    field :violates_thread_gate, :boolean
    field :violates_embedding_rules, :boolean
    field :has_thread_gate, :boolean
    field :has_post_gate, :boolean
    field :created_at, :utc_datetime_usec
    field :indexed_at, :utc_datetime_usec
    field :sort_at, :utc_datetime_usec, read_after_writes: true
  end
end

defmodule Aerox.AppView.Schema.PostEmbedImage do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "post_embed_image" do
    field :post_uri, :string, primary_key: true
    field :position, :integer, primary_key: true
    field :image_cid, :string
    field :alt, :string, default: ""
  end
end

defmodule Aerox.AppView.Schema.PostEmbedExternal do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:post_uri, :string, autogenerate: false}
  schema "post_embed_external" do
    field :uri, :string
    field :title, :string, default: ""
    field :description, :string, default: ""
    field :thumb_cid, :string
  end
end

defmodule Aerox.AppView.Schema.PostEmbedRecord do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:post_uri, :string, autogenerate: false}
  schema "post_embed_record" do
    field :embed_uri, :string
    field :embed_cid, :string
  end
end

defmodule Aerox.AppView.Schema.PostEmbedVideo do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:post_uri, :string, autogenerate: false}
  schema "post_embed_video" do
    field :video_cid, :string
    field :alt, :string
  end
end

defmodule Aerox.AppView.Schema.PostAgg do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:uri, :string, autogenerate: false}
  schema "post_agg" do
    field :like_count, :integer, default: 0
    field :reply_count, :integer, default: 0
    field :repost_count, :integer, default: 0
    field :quote_count, :integer, default: 0
    field :bookmark_count, :integer, default: 0
  end
end

defmodule Aerox.AppView.Schema.ProfileAgg do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:did, :string, autogenerate: false}
  schema "profile_agg" do
    field :followers_count, :integer, default: 0
    field :follows_count, :integer, default: 0
    field :posts_count, :integer, default: 0
  end
end

defmodule Aerox.AppView.Schema.FeedItem do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:uri, :string, autogenerate: false}
  schema "feed_item" do
    field :cid, :string
    field :type, :string
    field :post_uri, :string
    field :originator_did, :string
    field :sort_at, :utc_datetime_usec
  end
end

defmodule Aerox.AppView.Schema.Quote do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:uri, :string, autogenerate: false}
  schema "quote" do
    field :cid, :string
    field :subject, :string
    field :subject_cid, :string
    field :created_at, :utc_datetime_usec
    field :indexed_at, :utc_datetime_usec
    field :sort_at, :utc_datetime_usec, read_after_writes: true
  end
end

for {mod, table} <- [{Aerox.AppView.Schema.Like, "like"}, {Aerox.AppView.Schema.Repost, "repost"}] do
  defmodule mod do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:uri, :string, autogenerate: false}
    schema table do
      field :cid, :string
      field :creator, :string
      field :subject, :string
      field :subject_cid, :string
      field :via, :string
      field :via_cid, :string
      field :created_at, :utc_datetime_usec
      field :indexed_at, :utc_datetime_usec
      field :sort_at, :utc_datetime_usec, read_after_writes: true
    end
  end
end

for {mod, table} <- [
      {Aerox.AppView.Schema.Follow, "follow"},
      {Aerox.AppView.Schema.ActorBlock, "actor_block"}
    ] do
  defmodule mod do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:uri, :string, autogenerate: false}
    schema table do
      field :cid, :string
      field :creator, :string
      field :subject_did, :string
      field :created_at, :utc_datetime_usec
      field :indexed_at, :utc_datetime_usec
      field :sort_at, :utc_datetime_usec, read_after_writes: true
    end
  end
end

defmodule Aerox.AppView.Schema.List do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:uri, :string, autogenerate: false}
  schema "list" do
    field :cid, :string
    field :creator, :string
    field :name, :string
    field :purpose, :string
    field :description, :string
    field :description_facets, {:array, :map}
    field :avatar_cid, :string
    field :created_at, :utc_datetime_usec
    field :indexed_at, :utc_datetime_usec
    field :sort_at, :utc_datetime_usec, read_after_writes: true
  end
end

defmodule Aerox.AppView.Schema.ListItem do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:uri, :string, autogenerate: false}
  schema "list_item" do
    field :cid, :string
    field :creator, :string
    field :subject_did, :string
    field :list_uri, :string
    field :created_at, :utc_datetime_usec
    field :indexed_at, :utc_datetime_usec
    field :sort_at, :utc_datetime_usec, read_after_writes: true
  end
end

defmodule Aerox.AppView.Schema.ListBlock do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:uri, :string, autogenerate: false}
  schema "list_block" do
    field :cid, :string
    field :creator, :string
    field :subject_uri, :string
    field :created_at, :utc_datetime_usec
    field :indexed_at, :utc_datetime_usec
    field :sort_at, :utc_datetime_usec, read_after_writes: true
  end
end

defmodule Aerox.AppView.Schema.Profile do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:uri, :string, autogenerate: false}
  schema "profile" do
    field :cid, :string
    field :creator, :string
    field :display_name, :string
    field :description, :string
    field :avatar_cid, :string
    field :banner_cid, :string
    field :joined_via_starter_pack_uri, :string
    field :pinned_post, :string
    field :pinned_post_cid, :string
    field :created_at, :utc_datetime_usec
    field :indexed_at, :utc_datetime_usec
  end
end

defmodule Aerox.AppView.Schema.FeedGenerator do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:uri, :string, autogenerate: false}
  schema "feed_generator" do
    field :cid, :string
    field :creator, :string
    field :feed_did, :string
    field :display_name, :string
    field :description, :string
    field :description_facets, {:array, :map}
    field :avatar_cid, :string
    field :created_at, :utc_datetime_usec
    field :indexed_at, :utc_datetime_usec
    field :sort_at, :utc_datetime_usec, read_after_writes: true
  end
end

for {mod, table} <- [{Aerox.AppView.Schema.Labeler, "labeler"}] do
  defmodule mod do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:uri, :string, autogenerate: false}
    schema table do
      field :cid, :string
      field :creator, :string
      field :created_at, :utc_datetime_usec
      field :indexed_at, :utc_datetime_usec
      field :sort_at, :utc_datetime_usec, read_after_writes: true
    end
  end
end

defmodule Aerox.AppView.Schema.StarterPack do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:uri, :string, autogenerate: false}
  schema "starter_pack" do
    field :cid, :string
    field :creator, :string
    field :name, :string
    field :created_at, :utc_datetime_usec
    field :indexed_at, :utc_datetime_usec
    field :sort_at, :utc_datetime_usec, read_after_writes: true
  end
end

for {mod, table} <- [
      {Aerox.AppView.Schema.ThreadGate, "thread_gate"},
      {Aerox.AppView.Schema.PostGate, "post_gate"}
    ] do
  defmodule mod do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:uri, :string, autogenerate: false}
    schema table do
      field :cid, :string
      field :creator, :string
      field :post_uri, :string
      field :created_at, :utc_datetime_usec
      field :indexed_at, :utc_datetime_usec
    end
  end
end

defmodule Aerox.AppView.Schema.Verification do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:uri, :string, autogenerate: false}
  schema "verification" do
    field :cid, :string
    field :rkey, :string
    field :creator, :string
    field :subject, :string
    field :handle, :string
    field :display_name, :string
    field :created_at, :utc_datetime_usec
    field :indexed_at, :utc_datetime_usec
    field :sort_at, :utc_datetime_usec, read_after_writes: true
  end
end

defmodule Aerox.AppView.Schema.ActorStatus do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:did, :string, autogenerate: false}
  schema "actor_status" do
    field :uri, :string
    field :cid, :string
    field :status, :string
    field :expires_at, :utc_datetime_usec
    field :created_at, :utc_datetime_usec
    field :indexed_at, :utc_datetime_usec
  end
end

defmodule Aerox.AppView.Schema.Notification do
  @moduledoc false
  use Ecto.Schema

  schema "notification" do
    field :did, :string
    field :record_uri, :string
    field :record_cid, :string
    field :author, :string
    field :reason, :string
    field :reason_subject, :string
    field :sort_at, :utc_datetime_usec
  end
end

defmodule Aerox.AppView.Schema.Label do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "label" do
    field :src, :string, primary_key: true
    field :uri, :string, primary_key: true
    field :cid, :string, primary_key: true
    field :val, :string, primary_key: true
    field :neg, :boolean, default: false
    field :cts, :utc_datetime_usec
    field :exp, :utc_datetime_usec
    field :sig, :binary
  end
end

defmodule Aerox.AppView.Schema.LabelSubscription do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:src, :string, autogenerate: false}
  schema "label_subscription" do
    field :cursor, :integer, default: 0
    field :updated_at, :utc_datetime_usec
  end
end

defmodule Aerox.AppView.Schema.Mute do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "mute" do
    field :muted_by_did, :string, primary_key: true
    field :subject_did, :string, primary_key: true
    field :created_at, :utc_datetime_usec
  end
end

defmodule Aerox.AppView.Schema.ListMute do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "list_mute" do
    field :muted_by_did, :string, primary_key: true
    field :list_uri, :string, primary_key: true
    field :created_at, :utc_datetime_usec
  end
end

defmodule Aerox.AppView.Schema.ThreadMute do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "thread_mute" do
    field :muted_by_did, :string, primary_key: true
    field :root_uri, :string, primary_key: true
    field :created_at, :utc_datetime_usec
  end
end

defmodule Aerox.AppView.Schema.Bookmark do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "bookmark" do
    field :creator, :string, primary_key: true
    field :key, :string, primary_key: true
    field :subject_uri, :string
    field :subject_cid, :string
    field :indexed_at, :utc_datetime_usec
  end
end

defmodule Aerox.AppView.Schema.PrivateData do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "private_data" do
    field :actor_did, :string, primary_key: true
    field :namespace, :string, primary_key: true
    field :key, :string, primary_key: true
    field :payload, :map
    field :indexed_at, :utc_datetime_usec
    field :updated_at, :utc_datetime_usec
  end
end

defmodule Aerox.AppView.Schema.Subscription do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "subscription" do
    field :service, :string, primary_key: true
    field :method, :string, primary_key: true
    field :state, :map
    field :updated_at, :utc_datetime_usec
  end
end
