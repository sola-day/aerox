defmodule Aerox.AppView.Repo.Migrations.AddPostSearchFilters do
  @moduledoc """
  The `tag` and `mentions` filters of `app.bsky.feed.searchPosts`. `hashtags`
  is the lexicon's "rich-text facet or tag field", lower-cased; `mentions` the
  DIDs of the mention facets. `tags` stays the record's own field, as
  upstream's column. Existing rows are filled from their stored records.
  """
  use Ecto.Migration

  def up do
    alter table(:post) do
      add :hashtags, {:array, :text}
      add :mentions, {:array, :text}
    end

    execute("""
    UPDATE post p SET
      hashtags = NULLIF(ARRAY(
        SELECT DISTINCT lower(t #>> '{}') FROM jsonb_path_query(r.json,
          '$.tags[*] ? (@.type() == "string")') t
        UNION
        SELECT lower(t #>> '{}') FROM jsonb_path_query(r.json,
          '$.facets[*].features[*] ? (@."$type" == "app.bsky.richtext.facet#tag").tag ? (@.type() == "string")') t
      ), '{}'),
      mentions = NULLIF(ARRAY(
        SELECT DISTINCT d #>> '{}' FROM jsonb_path_query(r.json,
          '$.facets[*].features[*] ? (@."$type" == "app.bsky.richtext.facet#mention").did ? (@.type() == "string")') d
      ), '{}')
    FROM record r WHERE r.uri = p.uri
    """)

    execute("CREATE INDEX post_hashtags_idx ON post USING gin (hashtags)")
    execute("CREATE INDEX post_mentions_idx ON post USING gin (mentions)")
    # searchPosts with no text and no author pages the whole table by recency
    create index(:post, [:sort_at, :cid])
  end

  def down do
    drop index(:post, [:sort_at, :cid])
    execute("DROP INDEX post_mentions_idx")
    execute("DROP INDEX post_hashtags_idx")

    alter table(:post) do
      remove :hashtags
      remove :mentions
    end
  end
end
