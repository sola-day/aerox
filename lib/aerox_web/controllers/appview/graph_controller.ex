defmodule AeroxWeb.AppView.GraphController do
  @moduledoc "`app.bsky.graph.*` on the AppView host (DESIGN §15.3, §15.7; upstream `api/app/bsky/graph/*`)."
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  import AeroxWeb.AppView.Helpers
  alias Aerox.AppView.Graph

  # ------------------------------------------------------------- queries

  def get_follows(conn, _) do
    p = params!(conn, "app.bsky.graph.getFollows")
    state = state(conn)

    case Graph.follows(p["actor"], p["limit"], p["cursor"], state) do
      {:ok, body} -> respond_labeled(conn, state, compact(body))
      {:error, reason} -> fail!(reason, p["actor"])
    end
  end

  def get_followers(conn, _) do
    p = params!(conn, "app.bsky.graph.getFollowers")
    state = state(conn)

    case Graph.followers(p["actor"], p["limit"], p["cursor"], state) do
      {:ok, body} -> respond_labeled(conn, state, compact(body))
      {:error, reason} -> fail!(reason, p["actor"])
    end
  end

  def get_known_followers(conn, _) do
    p = params!(conn, "app.bsky.graph.getKnownFollowers")
    _ = viewer!(conn)
    state = state(conn)

    case Graph.known_followers(p["actor"], p["limit"], state) do
      {:ok, body} -> respond_labeled(conn, state, body)
      {:error, reason} -> fail!(reason, p["actor"])
    end
  end

  def get_blocks(conn, _) do
    p = params!(conn, "app.bsky.graph.getBlocks")
    _ = viewer!(conn)
    state = state(conn)
    respond_labeled(conn, state, compact(Graph.blocks(p["limit"], p["cursor"], state)))
  end

  def get_mutes(conn, _) do
    p = params!(conn, "app.bsky.graph.getMutes")
    _ = viewer!(conn)
    state = state(conn)
    respond_labeled(conn, state, compact(Graph.mutes(p["limit"], p["cursor"], state)))
  end

  def get_list(conn, _) do
    p = params!(conn, "app.bsky.graph.getList")
    state = state(conn)

    case Graph.list(p["list"], p["limit"], p["cursor"], state) do
      {:ok, body} -> respond_labeled(conn, state, compact(body))
      {:error, :not_found} -> raise AeroxWeb.XRPC.Error.invalid_request("List not found")
    end
  end

  def get_lists(conn, _) do
    p = params!(conn, "app.bsky.graph.getLists")
    state = state(conn)

    case Graph.lists(p["actor"], p["limit"], p["cursor"], state) do
      {:ok, body} -> respond_labeled(conn, state, compact(body))
      {:error, reason} -> fail!(reason)
    end
  end

  def get_list_mutes(conn, _) do
    p = params!(conn, "app.bsky.graph.getListMutes")
    _ = viewer!(conn)
    state = state(conn)
    respond_labeled(conn, state, compact(Graph.list_mutes(p["limit"], p["cursor"], state)))
  end

  def get_list_blocks(conn, _) do
    p = params!(conn, "app.bsky.graph.getListBlocks")
    _ = viewer!(conn)
    state = state(conn)
    respond_labeled(conn, state, compact(Graph.list_blocks(p["limit"], p["cursor"], state)))
  end

  def get_relationships(conn, _) do
    p = params!(conn, "app.bsky.graph.getRelationships")
    respond(conn, Graph.relationships(p["actor"], p["others"] || []))
  end

  def get_starter_pack(conn, _) do
    p = params!(conn, "app.bsky.graph.getStarterPack")
    state = state(conn)

    case Graph.starter_pack(p["starterPack"], state) do
      {:ok, view} -> respond_labeled(conn, state, %{"starterPack" => view})
      {:error, _} -> raise AeroxWeb.XRPC.Error.invalid_request("Starter pack not found")
    end
  end

  def get_starter_packs(conn, _) do
    p = params!(conn, "app.bsky.graph.getStarterPacks")
    state = state(conn)
    respond_labeled(conn, state, %{"starterPacks" => Graph.starter_packs(p["uris"] || [], state)})
  end

  def get_actor_starter_packs(conn, _) do
    p = params!(conn, "app.bsky.graph.getActorStarterPacks")
    state = state(conn)

    case Graph.actor_starter_packs(p["actor"], p["limit"], p["cursor"], state) do
      {:ok, body} -> respond_labeled(conn, state, compact(body))
      {:error, reason} -> fail!(reason)
    end
  end

  # ------------------------------------------------- mutes (DESIGN §15.7)

  def mute_actor(conn, _) do
    viewer = viewer!(conn)
    %{"actor" => actor} = input!(conn, "app.bsky.graph.muteActor")
    ok!(conn, Graph.mute_actor(viewer, actor))
  end

  def unmute_actor(conn, _) do
    viewer = viewer!(conn)
    %{"actor" => actor} = input!(conn, "app.bsky.graph.unmuteActor")
    ok!(conn, Graph.unmute_actor(viewer, actor))
  end

  def mute_actor_list(conn, _) do
    viewer = viewer!(conn)
    %{"list" => list} = input!(conn, "app.bsky.graph.muteActorList")
    ok!(conn, Graph.mute_list(viewer, list))
  end

  def unmute_actor_list(conn, _) do
    viewer = viewer!(conn)
    %{"list" => list} = input!(conn, "app.bsky.graph.unmuteActorList")
    ok!(conn, Graph.unmute_list(viewer, list))
  end

  def mute_thread(conn, _) do
    viewer = viewer!(conn)
    %{"root" => root} = input!(conn, "app.bsky.graph.muteThread")
    ok!(conn, Graph.mute_thread(viewer, root))
  end

  def unmute_thread(conn, _) do
    viewer = viewer!(conn)
    %{"root" => root} = input!(conn, "app.bsky.graph.unmuteThread")
    ok!(conn, Graph.unmute_thread(viewer, root))
  end

  defp ok!(conn, :ok), do: send_resp(conn, 200, "")

  defp ok!(_conn, {:error, :not_found}),
    do: raise(AeroxWeb.XRPC.Error.invalid_request("Actor not found"))

  defp ok!(_conn, {:error, reason}), do: fail!(reason)

  defp compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
end
