defmodule AeroxWeb.AppView.ActorController do
  @moduledoc "`app.bsky.actor.*` on the AppView host (DESIGN §15.3, §15.8; upstream `api/app/bsky/actor/*`)."
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  import AeroxWeb.AppView.Helpers
  alias Aerox.AppView.Actors

  def get_profile(conn, _) do
    params = params!(conn, "app.bsky.actor.getProfile")
    state = state(conn)

    case Actors.get_profile(params["actor"], state) do
      {:ok, view} -> respond_labeled(conn, state, view)
      {:error, reason} -> fail!(reason)
    end
  end

  def get_profiles(conn, _) do
    params = params!(conn, "app.bsky.actor.getProfiles")
    state = state(conn)
    respond_labeled(conn, state, %{"profiles" => Actors.get_profiles(params["actors"], state)})
  end

  # DESIGN §15.4: discovery is not in v1; the client tolerates an empty list
  def get_suggestions(conn, _) do
    _ = params!(conn, "app.bsky.actor.getSuggestions")
    respond(conn, %{"actors" => []})
  end

  def search_actors(conn, _) do
    params = params!(conn, "app.bsky.actor.searchActors")
    state = state(conn)
    term = params["q"] || params["term"] || ""

    respond_labeled(
      conn,
      state,
      compact(Actors.search_actors(term, params["limit"] || 25, params["cursor"], state))
    )
  end

  def search_actors_typeahead(conn, _) do
    params = params!(conn, "app.bsky.actor.searchActorsTypeahead")
    state = state(conn)
    term = params["q"] || params["term"] || ""

    respond_labeled(conn, state, %{
      "actors" => Actors.typeahead(term, params["limit"] || 10, state)
    })
  end

  defp compact(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()
end
