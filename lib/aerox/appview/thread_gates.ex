defmodule Aerox.AppView.ThreadGates do
  @moduledoc "Thread gate and post gate rules (upstream `views/util.ts` parseThreadGate/parsePostgate and `violatesThreadGate`)."
  import Ecto.Query
  alias Aerox.ATProto.Syntax
  alias Aerox.AppView.Repo
  alias Aerox.AppView.Schema.{Follow, ListItem, Record}

  @doc "The gate record URI for a post: same repo and rkey under the gate collection."
  def gate_uri(post_uri), do: sibling_uri(post_uri, "app.bsky.feed.threadgate")
  def postgate_uri(post_uri), do: sibling_uri(post_uri, "app.bsky.feed.postgate")

  defp sibling_uri(nil, _), do: nil

  defp sibling_uri(post_uri, collection) do
    case Syntax.parse_at_uri(post_uri) do
      {:ok, %{authority: did, rkey: rkey}} -> "at://#{did}/#{collection}/#{rkey}"
      _ -> nil
    end
  end

  @doc "The thread gate record (JSON map) of a root post, or nil."
  def gate_record(post_uri) do
    case gate_uri(post_uri) do
      nil -> nil
      uri -> Repo.one(from(r in Record, where: r.uri == ^uri, select: r.json))
    end
  end

  def postgate_record(post_uri) do
    case postgate_uri(post_uri) do
      nil -> nil
      uri -> Repo.one(from(r in Record, where: r.uri == ^uri, select: r.json))
    end
  end

  @doc "Upstream parseThreadGate."
  def parse(replier_did, owner_did, root_record, gate) do
    cond do
      replier_did == owner_did ->
        %{can_reply: true}

      is_nil(gate) or is_nil(gate["allow"]) ->
        %{can_reply: true}

      true ->
        allow = gate["allow"]
        types = Enum.map(allow, & &1["$type"])
        allow_mentions = "app.bsky.feed.threadgate#mentionRule" in types
        allow_follower = "app.bsky.feed.threadgate#followerRule" in types
        allow_following = "app.bsky.feed.threadgate#followingRule" in types
        lists = for %{"$type" => "app.bsky.feed.threadgate#listRule", "list" => l} <- allow, do: l

        mentioned? =
          allow_mentions and
            Enum.any?(root_record["facets"] || [], fn facet ->
              Enum.any?(
                facet["features"] || [],
                &(&1["$type"] == "app.bsky.richtext.facet#mention" and &1["did"] == replier_did)
              )
            end)

        %{
          can_reply: mentioned?,
          allow_mentions: allow_mentions,
          allow_follower: allow_follower,
          allow_following: allow_following,
          allow_list_uris: lists
        }
    end
  end

  @doc "Upstream violatesThreadGate: may `replier_did` reply in `owner_did`'s thread?"
  def violates?(replier_did, owner_did, root_record, gate) do
    parsed = parse(replier_did, owner_did, root_record, gate)

    cond do
      parsed[:can_reply] ->
        false

      not parsed[:allow_follower] and not parsed[:allow_following] and
          parsed[:allow_list_uris] == [] ->
        true

      parsed[:allow_following] and
          Repo.exists?(
            from(f in Follow, where: f.creator == ^owner_did and f.subject_did == ^replier_did)
          ) ->
        false

      parsed[:allow_follower] and
          Repo.exists?(
            from(f in Follow, where: f.subject_did == ^owner_did and f.creator == ^replier_did)
          ) ->
        false

      parsed[:allow_list_uris] != [] and
          Repo.exists?(
            from(i in ListItem,
              where: i.list_uri in ^parsed[:allow_list_uris] and i.subject_did == ^replier_did
            )
          ) ->
        false

      true ->
        true
    end
  end

  @doc "Upstream parsePostgate + validatePostEmbed: does the quoted post's gate forbid `quoter_did` embedding it?"
  def embedding_disabled?(quoted_uri, quoter_did) do
    author =
      case Syntax.parse_at_uri(quoted_uri),
        do: (
          {:ok, %{authority: d}} -> d
          _ -> nil
        )

    cond do
      quoter_did == author ->
        false

      true ->
        case postgate_record(quoted_uri) do
          nil ->
            false

          gate ->
            Enum.any?(
              gate["embeddingRules"] || [],
              &(&1["$type"] == "app.bsky.feed.postgate#disableRule")
            )
        end
    end
  end

  @doc "Upstream parsePostgate for hydration: `%{can_embed: boolean}`."
  def can_embed?(gate, viewer_did, author_did) do
    cond do
      viewer_did == author_did ->
        true

      is_nil(gate) or is_nil(gate["embeddingRules"]) ->
        true

      true ->
        not Enum.any?(
          gate["embeddingRules"],
          &(&1["$type"] == "app.bsky.feed.postgate#disableRule")
        )
    end
  end
end
