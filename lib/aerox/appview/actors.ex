defmodule Aerox.AppView.Actors do
  @moduledoc """
  The `app.bsky.actor.*` read path (DESIGN §15.3, upstream
  `api/app/bsky/actor/*`): skeleton → hydrate → present. Functions take a
  hydration state from `Aerox.AppView.Hydration.new/1` (viewer and
  labelers already set) and return plain view maps or `{:error, reason}`;
  the controllers map reasons to XRPC errors.
  """
  import Ecto.Query
  alias Aerox.AppView.{Hydration, Repo, Search, Views}
  alias Aerox.AppView.Schema, as: S

  # ---------------------------------------------------------- resolution

  @doc """
  Upstream `getDids`: a DID passes through; a handle resolves through the
  actor table (the verified handle we indexed) and then the identity cache.
  """
  @spec resolve_did(String.t() | nil) :: String.t() | nil
  def resolve_did("did:" <> _ = did), do: did

  def resolve_did(handle) when is_binary(handle) do
    handle = handle |> String.trim() |> String.trim_leading("@") |> String.downcase()

    cond do
      handle == "" ->
        nil

      did = Repo.one(from(a in S.Actor, where: a.handle == ^handle, select: a.did, limit: 1)) ->
        did

      true ->
        case Aerox.Identity.resolve_handle(Aerox.AppView.Identity, handle) do
          {:ok, did} -> did
          _ -> nil
        end
    end
  end

  def resolve_did(_), do: nil

  @doc "Upstream `getDidsDefined`: the DIDs of the actors that resolve, in order."
  def resolve_dids(actors), do: actors |> Enum.map(&resolve_did/1) |> Enum.reject(&is_nil/1)

  @doc "Is the actor indexed at all (upstream `actors.get(did)` being defined)?"
  def exists?(did, state), do: match?(%{exists: true}, state.actors[did])

  # ------------------------------------------------------------ profiles

  @doc "getProfile: the detailed view, or why not (`:not_found`, `:takendown`, `:deactivated`)."
  def get_profile(actor, state) do
    with did when is_binary(did) <- resolve_did(actor) || {:error, :not_found},
         state = Hydration.hydrate_profiles(state, [did], detailed: true),
         true <- exists?(did, state) || {:error, :not_found},
         %{} = view <- Views.profile_detailed(did, state) || {:error, :not_found} do
      cond do
        state.ctx.include_takedowns -> {:ok, view}
        Views.actor_takendown?(did, state) -> {:error, :takendown}
        state.actors[did].upstream_status == "deactivated" -> {:error, :deactivated}
        true -> {:ok, view}
      end
    end
  end

  @doc "getProfiles: detailed views of every actor that resolves and is indexed."
  def get_profiles(actors, state) do
    dids = resolve_dids(actors)
    state = Hydration.hydrate_profiles(state, dids, detailed: true)

    dids
    |> Enum.filter(&exists?(&1, state))
    |> Enum.reject(&(Views.actor_no_hosted?(&1, state) and not state.ctx.include_takedowns))
    |> Enum.map(&Views.profile_detailed(&1, state))
    |> Enum.reject(&is_nil/1)
  end

  @doc "Profile views (`#profileView`) of `dids`, dropping unindexed, unhosted and viewer-blocked actors."
  def profiles(dids, state, opts \\ []) do
    view = Keyword.get(opts, :view, :profile)
    state = Hydration.hydrate_profiles(state, dids)

    views =
      dids
      |> Enum.filter(&exists?(&1, state))
      |> Enum.reject(&Views.actor_no_hosted?(&1, state))
      |> Enum.reject(
        &(Keyword.get(opts, :no_blocks, true) and Views.viewer_block_exists?(&1, state))
      )
      |> Enum.map(&apply(Views, view, [&1, state]))
      |> Enum.reject(&is_nil/1)

    {views, state}
  end

  # -------------------------------------------------------------- search

  @doc "searchActors: `#profileView`s and the next cursor."
  def search_actors(term, limit, cursor, state) do
    {dids, next} = Search.search_actors(term, limit, cursor)
    {views, _state} = profiles(dids, state)
    %{"actors" => views, "cursor" => next}
  end

  @doc """
  searchActorsTypeahead: `#profileViewBasic`s. As upstream, an exact handle
  match is always shown so people can find profiles they have blocked.
  """
  def typeahead(term, limit, state) do
    dids = Search.typeahead(term, limit)
    state = Hydration.hydrate_profiles(state, dids)
    exact = term |> Search.clean() |> String.downcase()

    dids
    |> Enum.filter(&exists?(&1, state))
    |> Enum.reject(&Views.actor_no_hosted?(&1, state))
    |> Enum.filter(fn did ->
      state.actors[did].handle == exact or not Views.viewer_block_exists?(did, state)
    end)
    |> Enum.map(&Views.profile_basic(&1, state))
    |> Enum.reject(&is_nil/1)
  end
end
