defmodule Aerox.AppView.Plugins do
  @moduledoc "The nineteen record plugins (DESIGN §15.2), keyed by collection."
  alias Aerox.AppView.Plugins, as: P

  @plugins [
    P.Post,
    P.Like,
    P.Repost,
    P.Follow,
    P.Block,
    P.List,
    P.ListItem,
    P.ListBlock,
    P.Profile,
    P.FeedGenerator,
    P.Labeler,
    P.StarterPack,
    P.ThreadGate,
    P.PostGate,
    P.Verification,
    P.Status,
    P.ChatDeclaration,
    P.NotifDeclaration,
    P.GermDeclaration
  ]

  @by_collection Map.new(@plugins, &{&1.collection(), &1})

  def all, do: @plugins
  def for_collection(collection), do: Map.get(@by_collection, collection)
  def collections, do: Map.keys(@by_collection)
end
