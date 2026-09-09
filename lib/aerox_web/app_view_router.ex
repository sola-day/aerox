defmodule AeroxWeb.AppViewRouter do
  @moduledoc """
  The AppView's HTTP surface (DESIGN §15, §16), dispatched by
  `AeroxWeb.Dispatch` when the request host is
  `Aerox.AppView.Config.hostname/0`: the `app.bsky.*` read path under
  `/xrpc`, the image CDN under `/img`, and the service DID document.
  """
  use AeroxWeb, :router

  pipeline :appview do
    plug :accepts, ["json"]
    plug AeroxWeb.Plugs.ClientIP
    plug AeroxWeb.Plugs.RateLimit, :global_ip
    plug AeroxWeb.Plugs.ServiceEnabled, :appview
    plug AeroxWeb.AppView.Auth
  end

  pipeline :img do
    plug AeroxWeb.Plugs.ClientIP
    plug AeroxWeb.Plugs.RateLimit, :global_ip
    plug AeroxWeb.Plugs.ServiceEnabled, :appview
  end

  scope "/", AeroxWeb.AppView do
    pipe_through :appview
    get "/", MetaController, :home
    get "/_health", MetaController, :health
    get "/.well-known/did.json", MetaController, :did_json
  end

  scope "/img" do
    pipe_through :img
    forward "/", AeroxWeb.Image.Plug
  end

  scope "/xrpc", AeroxWeb.AppView do
    pipe_through :appview

    # actor
    get "/app.bsky.actor.getProfile", ActorController, :get_profile
    get "/app.bsky.actor.getProfiles", ActorController, :get_profiles
    get "/app.bsky.actor.getSuggestions", ActorController, :get_suggestions
    get "/app.bsky.actor.searchActors", ActorController, :search_actors
    get "/app.bsky.actor.searchActorsTypeahead", ActorController, :search_actors_typeahead

    # feed
    get "/app.bsky.feed.getTimeline", FeedController, :get_timeline
    get "/app.bsky.feed.getAuthorFeed", FeedController, :get_author_feed
    get "/app.bsky.feed.getPostThread", FeedController, :get_post_thread
    get "/app.bsky.feed.getPosts", FeedController, :get_posts
    get "/app.bsky.feed.getLikes", FeedController, :get_likes
    get "/app.bsky.feed.getRepostedBy", FeedController, :get_reposted_by
    get "/app.bsky.feed.getQuotes", FeedController, :get_quotes
    get "/app.bsky.feed.getActorLikes", FeedController, :get_actor_likes
    get "/app.bsky.feed.getFeed", FeedController, :get_feed
    get "/app.bsky.feed.getFeedGenerator", FeedController, :get_feed_generator
    get "/app.bsky.feed.getFeedGenerators", FeedController, :get_feed_generators
    get "/app.bsky.feed.getActorFeeds", FeedController, :get_actor_feeds
    get "/app.bsky.feed.getListFeed", FeedController, :get_list_feed
    get "/app.bsky.feed.searchPosts", FeedController, :search_posts
    get "/app.bsky.feed.describeFeedGenerator", FeedController, :describe_feed_generator

    # graph
    get "/app.bsky.graph.getFollows", GraphController, :get_follows
    get "/app.bsky.graph.getFollowers", GraphController, :get_followers
    get "/app.bsky.graph.getKnownFollowers", GraphController, :get_known_followers
    get "/app.bsky.graph.getBlocks", GraphController, :get_blocks
    get "/app.bsky.graph.getMutes", GraphController, :get_mutes
    get "/app.bsky.graph.getList", GraphController, :get_list
    get "/app.bsky.graph.getLists", GraphController, :get_lists
    get "/app.bsky.graph.getListMutes", GraphController, :get_list_mutes
    get "/app.bsky.graph.getListBlocks", GraphController, :get_list_blocks
    get "/app.bsky.graph.getRelationships", GraphController, :get_relationships
    get "/app.bsky.graph.getStarterPack", GraphController, :get_starter_pack
    get "/app.bsky.graph.getStarterPacks", GraphController, :get_starter_packs
    get "/app.bsky.graph.getActorStarterPacks", GraphController, :get_actor_starter_packs
    post "/app.bsky.graph.muteActor", GraphController, :mute_actor
    post "/app.bsky.graph.unmuteActor", GraphController, :unmute_actor
    post "/app.bsky.graph.muteActorList", GraphController, :mute_actor_list
    post "/app.bsky.graph.unmuteActorList", GraphController, :unmute_actor_list
    post "/app.bsky.graph.muteThread", GraphController, :mute_thread
    post "/app.bsky.graph.unmuteThread", GraphController, :unmute_thread

    # notifications
    get "/app.bsky.notification.listNotifications", NotificationController, :list_notifications
    get "/app.bsky.notification.getUnreadCount", NotificationController, :get_unread_count
    post "/app.bsky.notification.updateSeen", NotificationController, :update_seen

    # labeler
    get "/app.bsky.labeler.getServices", LabelerController, :get_services

    # unspecced (ouranos calls this; empty by design, DESIGN §15.4)
    get "/app.bsky.unspecced.getPopularFeedGenerators",
        FeedController,
        :get_popular_feed_generators

    get "/app.bsky.unspecced.getConfig", MetaController, :get_config

    match :*, "/*method", MetaController, :not_implemented
  end
end
