defmodule Aerox.AppView.Repo.Migrations.CreateAppviewTables do
  @moduledoc """
  The AppView's index (DESIGN §15.2, §15.5–15.7), mirroring upstream
  `bsky/src/data-plane/server/db/tables/*` table for table, with timestamps
  as `timestamptz` and `sort_at` as a stored generated column
  (`least(created_at, indexed_at)`). Cursors pack `sort_at` in epoch
  milliseconds ‖ cid exactly as upstream's `TimeCidKeyset`.
  """
  use Ecto.Migration

  defp sort_at, do: :"least(created_at, indexed_at)"

  defp timestamps_with_sort do
    add :created_at, :utc_datetime_usec, null: false
    add :indexed_at, :utc_datetime_usec, null: false
    add :sort_at, :utc_datetime_usec, generated: "ALWAYS AS (least(created_at, indexed_at)) STORED"
  end

  def change do
    _ = sort_at()

    # ---- actors --------------------------------------------------------
    create table(:actor, primary_key: false) do
      add :did, :text, primary_key: true
      add :handle, :text
      add :indexed_at, :utc_datetime_usec, null: false
      add :takedown_ref, :text
      add :upstream_status, :text
      add :trusted_verifier, :boolean, null: false, default: false
    end

    create index(:actor, [:handle])
    execute("CREATE INDEX actor_handle_trgm_idx ON actor USING gin (handle gin_trgm_ops)", "DROP INDEX actor_handle_trgm_idx")

    create table(:actor_sync, primary_key: false) do
      add :did, :text, primary_key: true
      add :commit_cid, :text, null: false
      add :repo_rev, :text
    end

    create table(:actor_state, primary_key: false) do
      add :did, :text, primary_key: true
      add :last_seen_notifs, :utc_datetime_usec, null: false
      add :priority_notifs, :boolean, null: false, default: false
      add :last_seen_priority_notifs, :utc_datetime_usec
    end

    # ---- generic record store -------------------------------------------
    create table(:record, primary_key: false) do
      add :uri, :text, primary_key: true
      add :cid, :text, null: false
      add :did, :text, null: false
      add :json, :map, null: false
      add :indexed_at, :utc_datetime_usec, null: false
      add :takedown_ref, :text
      add :tags, {:array, :text}
    end

    create index(:record, [:did])

    create table(:duplicate_record, primary_key: false) do
      add :uri, :text, primary_key: true
      add :cid, :text, null: false
      add :duplicate_of, :text, null: false
      add :indexed_at, :utc_datetime_usec, null: false
    end

    create index(:duplicate_record, [:duplicate_of])

    # ---- posts -----------------------------------------------------------
    create table(:post, primary_key: false) do
      add :uri, :text, primary_key: true
      add :cid, :text, null: false
      add :creator, :text, null: false
      add :text, :text, null: false
      add :reply_root, :text
      add :reply_root_cid, :text
      add :reply_parent, :text
      add :reply_parent_cid, :text
      add :langs, {:array, :text}
      add :tags, {:array, :text}
      add :invalid_reply_root, :boolean
      add :violates_thread_gate, :boolean
      add :violates_embedding_rules, :boolean
      add :has_thread_gate, :boolean
      add :has_post_gate, :boolean
      timestamps_with_sort()
    end

    create index(:post, [:creator, :sort_at])
    create index(:post, [:reply_parent])
    create index(:post, [:reply_root])
    execute("CREATE INDEX post_text_trgm_idx ON post USING gin (text gin_trgm_ops)", "DROP INDEX post_text_trgm_idx")

    create table(:post_embed_image, primary_key: false) do
      add :post_uri, :text, primary_key: true
      add :position, :integer, primary_key: true
      add :image_cid, :text, null: false
      add :alt, :text, null: false, default: ""
    end

    create table(:post_embed_external, primary_key: false) do
      add :post_uri, :text, primary_key: true
      add :uri, :text, null: false
      add :title, :text, null: false, default: ""
      add :description, :text, null: false, default: ""
      add :thumb_cid, :text
    end

    create table(:post_embed_record, primary_key: false) do
      add :post_uri, :text, primary_key: true
      add :embed_uri, :text, null: false
      add :embed_cid, :text, null: false
    end

    create index(:post_embed_record, [:embed_uri])

    create table(:post_embed_video, primary_key: false) do
      add :post_uri, :text, primary_key: true
      add :video_cid, :text, null: false
      add :alt, :text
    end

    create table(:post_agg, primary_key: false) do
      add :uri, :text, primary_key: true
      add :like_count, :bigint, null: false, default: 0
      add :reply_count, :bigint, null: false, default: 0
      add :repost_count, :bigint, null: false, default: 0
      add :quote_count, :bigint, null: false, default: 0
      add :bookmark_count, :bigint, null: false, default: 0
    end

    create table(:profile_agg, primary_key: false) do
      add :did, :text, primary_key: true
      add :followers_count, :bigint, null: false, default: 0
      add :follows_count, :bigint, null: false, default: 0
      add :posts_count, :bigint, null: false, default: 0
    end

    create table(:feed_item, primary_key: false) do
      add :uri, :text, primary_key: true
      add :cid, :text, null: false
      add :type, :text, null: false
      add :post_uri, :text, null: false
      add :originator_did, :text, null: false
      add :sort_at, :utc_datetime_usec, null: false
    end

    create index(:feed_item, [:originator_did, :sort_at, :cid])
    create index(:feed_item, [:post_uri])
    create index(:feed_item, [:sort_at, :cid])

    create table(:quote, primary_key: false) do
      add :uri, :text, primary_key: true
      add :cid, :text, null: false
      add :subject, :text, null: false
      add :subject_cid, :text, null: false
      timestamps_with_sort()
    end

    create index(:quote, [:subject, :sort_at])

    # ---- interactions ------------------------------------------------------
    for table <- [:like, :repost] do
      create table(table, primary_key: false) do
        add :uri, :text, primary_key: true
        add :cid, :text, null: false
        add :creator, :text, null: false
        add :subject, :text, null: false
        add :subject_cid, :text, null: false
        add :via, :text
        add :via_cid, :text
        timestamps_with_sort()
      end

      create unique_index(table, [:creator, :subject])
      create index(table, [:subject, :sort_at])
      create index(table, [:creator, :sort_at])
    end

    create table(:follow, primary_key: false) do
      add :uri, :text, primary_key: true
      add :cid, :text, null: false
      add :creator, :text, null: false
      add :subject_did, :text, null: false
      timestamps_with_sort()
    end

    create unique_index(:follow, [:creator, :subject_did])
    create index(:follow, [:subject_did, :sort_at])
    create index(:follow, [:creator, :sort_at])

    create table(:actor_block, primary_key: false) do
      add :uri, :text, primary_key: true
      add :cid, :text, null: false
      add :creator, :text, null: false
      add :subject_did, :text, null: false
      timestamps_with_sort()
    end

    create unique_index(:actor_block, [:creator, :subject_did])
    create index(:actor_block, [:subject_did])

    # ---- lists ---------------------------------------------------------------
    create table(:list, primary_key: false) do
      add :uri, :text, primary_key: true
      add :cid, :text, null: false
      add :creator, :text, null: false
      add :name, :text, null: false
      add :purpose, :text, null: false
      add :description, :text
      add :description_facets, :map
      add :avatar_cid, :text
      timestamps_with_sort()
    end

    create index(:list, [:creator])

    create table(:list_item, primary_key: false) do
      add :uri, :text, primary_key: true
      add :cid, :text, null: false
      add :creator, :text, null: false
      add :subject_did, :text, null: false
      add :list_uri, :text, null: false
      timestamps_with_sort()
    end

    create unique_index(:list_item, [:list_uri, :subject_did])
    create index(:list_item, [:subject_did])

    create table(:list_block, primary_key: false) do
      add :uri, :text, primary_key: true
      add :cid, :text, null: false
      add :creator, :text, null: false
      add :subject_uri, :text, null: false
      timestamps_with_sort()
    end

    create unique_index(:list_block, [:creator, :subject_uri])

    # ---- profiles and declarations ----------------------------------------------
    create table(:profile, primary_key: false) do
      add :uri, :text, primary_key: true
      add :cid, :text, null: false
      add :creator, :text, null: false
      add :display_name, :text
      add :description, :text
      add :avatar_cid, :text
      add :banner_cid, :text
      add :joined_via_starter_pack_uri, :text
      add :pinned_post, :text
      add :pinned_post_cid, :text
      add :created_at, :utc_datetime_usec
      add :indexed_at, :utc_datetime_usec, null: false
    end

    create unique_index(:profile, [:creator])
    execute("CREATE INDEX profile_display_name_trgm_idx ON profile USING gin (display_name gin_trgm_ops)", "DROP INDEX profile_display_name_trgm_idx")

    create table(:feed_generator, primary_key: false) do
      add :uri, :text, primary_key: true
      add :cid, :text, null: false
      add :creator, :text, null: false
      add :feed_did, :text, null: false
      add :display_name, :text, null: false
      add :description, :text
      add :description_facets, :map
      add :avatar_cid, :text
      timestamps_with_sort()
    end

    create index(:feed_generator, [:creator])

    create table(:labeler, primary_key: false) do
      add :uri, :text, primary_key: true
      add :cid, :text, null: false
      add :creator, :text, null: false
      timestamps_with_sort()
    end

    create table(:starter_pack, primary_key: false) do
      add :uri, :text, primary_key: true
      add :cid, :text, null: false
      add :creator, :text, null: false
      add :name, :text, null: false
      timestamps_with_sort()
    end

    create index(:starter_pack, [:creator])

    for table <- [:thread_gate, :post_gate] do
      create table(table, primary_key: false) do
        add :uri, :text, primary_key: true
        add :cid, :text, null: false
        add :creator, :text, null: false
        add :post_uri, :text, null: false
        add :created_at, :utc_datetime_usec, null: false
        add :indexed_at, :utc_datetime_usec, null: false
      end

      create unique_index(table, [:post_uri])
    end

    create table(:verification, primary_key: false) do
      add :uri, :text, primary_key: true
      add :cid, :text, null: false
      add :rkey, :text, null: false
      add :creator, :text, null: false
      add :subject, :text, null: false
      add :handle, :text, null: false
      add :display_name, :text, null: false
      timestamps_with_sort()
    end

    create index(:verification, [:subject])

    create table(:actor_status, primary_key: false) do
      add :did, :text, primary_key: true
      add :uri, :text, null: false
      add :cid, :text, null: false
      add :status, :text, null: false
      add :expires_at, :utc_datetime_usec
      add :created_at, :utc_datetime_usec, null: false
      add :indexed_at, :utc_datetime_usec, null: false
    end

    # ---- notifications ----------------------------------------------------------
    create table(:notification) do
      add :did, :text, null: false
      add :record_uri, :text, null: false
      add :record_cid, :text, null: false
      add :author, :text, null: false
      add :reason, :text, null: false
      add :reason_subject, :text
      add :sort_at, :utc_datetime_usec, null: false
    end

    create index(:notification, [:did, :sort_at])
    create index(:notification, [:record_uri])

    # ---- labels -------------------------------------------------------------------
    create table(:label, primary_key: false) do
      add :src, :text, primary_key: true
      add :uri, :text, primary_key: true
      add :cid, :text, primary_key: true
      add :val, :text, primary_key: true
      add :neg, :boolean, null: false, default: false
      add :cts, :utc_datetime_usec, null: false
      add :exp, :utc_datetime_usec
      add :sig, :binary
    end

    create index(:label, [:uri])

    create table(:label_subscription, primary_key: false) do
      add :src, :text, primary_key: true
      add :cursor, :bigint, null: false, default: 0
      add :updated_at, :utc_datetime_usec
    end

    # ---- private state (DESIGN §15.7) ---------------------------------------------
    create table(:mute, primary_key: false) do
      add :muted_by_did, :text, primary_key: true
      add :subject_did, :text, primary_key: true
      add :created_at, :utc_datetime_usec, null: false
    end

    create table(:list_mute, primary_key: false) do
      add :muted_by_did, :text, primary_key: true
      add :list_uri, :text, primary_key: true
      add :created_at, :utc_datetime_usec, null: false
    end

    create table(:thread_mute, primary_key: false) do
      add :muted_by_did, :text, primary_key: true
      add :root_uri, :text, primary_key: true
      add :created_at, :utc_datetime_usec, null: false
    end

    create table(:bookmark, primary_key: false) do
      add :creator, :text, primary_key: true
      add :key, :text, primary_key: true
      add :subject_uri, :text, null: false
      add :subject_cid, :text, null: false
      add :indexed_at, :utc_datetime_usec, null: false
    end

    create index(:bookmark, [:creator, :indexed_at])

    create table(:private_data, primary_key: false) do
      add :actor_did, :text, primary_key: true
      add :namespace, :text, primary_key: true
      add :key, :text, primary_key: true
      add :payload, :map, null: false
      add :indexed_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    # ---- ingest state (DESIGN §15.1) ----------------------------------------------
    create table(:subscription, primary_key: false) do
      add :service, :text, primary_key: true
      add :method, :text, primary_key: true
      add :state, :map, null: false
      add :updated_at, :utc_datetime_usec
    end
  end
end
