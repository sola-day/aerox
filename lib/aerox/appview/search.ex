defmodule Aerox.AppView.Search do
  @moduledoc """
  Search (DESIGN §15.8): a behaviour so an external engine (upstream's
  palomar / OpenSearch) can replace the default without touching the read
  path. Every callback returns a skeleton — DIDs or URIs plus a cursor —
  that the endpoints hydrate and present as usual.

  The backend is `config :aerox, Aerox.AppView, search_backend: Module`
  and defaults to `Aerox.AppView.Search.Postgres`.
  """

  @type cursor :: String.t() | nil

  @doc "Actors matching `term` (upstream data-plane `searchActors`): DIDs and the next cursor."
  @callback search_actors(term :: String.t(), limit :: pos_integer, cursor) ::
              {[String.t()], cursor}

  @doc "Typeahead: prefix matches on handle and display name, no cursor."
  @callback typeahead(term :: String.t(), limit :: pos_integer) :: [String.t()]

  @doc "Posts matching `term` (upstream data-plane `searchPosts`): URIs and the next cursor."
  @callback search_posts(term :: String.t(), limit :: pos_integer, cursor) ::
              {[String.t()], cursor}

  def backend, do: Aerox.AppView.Config.get(:search_backend) || __MODULE__.Postgres

  def search_actors(term, limit, cursor), do: backend().search_actors(term, limit, cursor)
  def typeahead(term, limit), do: backend().typeahead(term, limit)
  def search_posts(term, limit, cursor), do: backend().search_posts(term, limit, cursor)

  @doc "Upstream `cleanQuery`: trims and drops a leading `@` (handles are often typed that way)."
  def clean(term), do: term |> to_string() |> String.trim() |> String.trim_leading("@")

  @doc "Escapes a LIKE pattern's metacharacters so user input matches literally."
  def escape_like(s), do: Regex.replace(~r/[\\%_]/, s, fn m -> "\\" <> m end)
end

defmodule Aerox.AppView.Search.Postgres do
  @moduledoc """
  The default search backend (DESIGN §15.8): `pg_trgm`-indexed `ILIKE`
  over `actor.handle` and `profile.display_name` for actors (upstream's
  dev data-plane does a `LIKE` on the handle alone), and over `post.text`
  for posts — substring matching, which also covers CJK text that
  Postgres' text search cannot segment.
  """
  @behaviour Aerox.AppView.Search
  import Ecto.Query
  alias Aerox.AppView.{Cursor, Repo, Search}
  alias Aerox.AppView.Schema, as: S

  @impl true
  def search_actors(term, limit, cursor) do
    term = Search.clean(term)

    if term == "" do
      {[], nil}
    else
      pattern = "%" <> Search.escape_like(term) <> "%"

      query =
        from(a in S.Actor,
          left_join: p in S.Profile,
          on: p.creator == a.did,
          where: ilike(a.handle, ^pattern) or ilike(p.display_name, ^pattern),
          where: is_nil(a.takedown_ref),
          select: %{did: a.did, indexed_at: a.indexed_at}
        )

      # upstream IndexedAtDidKeyset: `<epoch ms>::<did>` over (indexed_at desc, did desc)
      query =
        case Cursor.parse(cursor) do
          nil ->
            query

          {dt, did} ->
            where(query, [a], a.indexed_at < ^dt or (a.indexed_at == ^dt and a.did < ^did))
        end

      rows =
        query
        |> order_by([a], desc: a.indexed_at, desc: a.did)
        |> limit(^limit)
        |> Repo.all()

      next =
        if length(rows) >= limit and rows != [] do
          last = List.last(rows)
          Cursor.pack(last.indexed_at, last.did)
        end

      {Enum.map(rows, & &1.did), next}
    end
  end

  @impl true
  def typeahead(term, limit) do
    term = Search.clean(term)

    if term == "" do
      []
    else
      prefix = Search.escape_like(term) <> "%"
      exact = String.downcase(term)

      Repo.all(
        from(a in S.Actor,
          left_join: p in S.Profile,
          on: p.creator == a.did,
          where: ilike(a.handle, ^prefix) or ilike(p.display_name, ^prefix),
          where: is_nil(a.takedown_ref),
          # exact handle matches first, then shorter (closer) handles
          order_by: [desc: fragment("? = ?", a.handle, ^exact), asc: a.handle],
          limit: ^limit,
          select: a.did
        )
      )
    end
  end

  @impl true
  def search_posts(term, limit, cursor) do
    {text, author} = parse_post_query(Search.clean(term))

    if text == "" and is_nil(author) do
      {[], nil}
    else
      pattern = "%" <> Search.escape_like(text) <> "%"
      query = from(p in S.Post, where: ilike(p.text, ^pattern))

      query =
        case author && resolve_author(author) do
          nil -> query
          did -> where(query, [p], p.creator == ^did)
        end

      rows = query |> Cursor.paginate(cursor, limit) |> Repo.all()
      {Enum.map(rows, & &1.uri), Cursor.next(rows, limit)}
    end
  end

  # upstream parsePostSearchQuery: a `from:<handle|did>` token narrows to an author
  defp parse_post_query(term) do
    {authors, words} =
      term
      |> String.split(~r/\s+/, trim: true)
      |> Enum.split_with(&String.starts_with?(&1, "from:"))

    author =
      case authors do
        ["from:" <> a | _] when a != "" -> String.trim_leading(a, "@")
        _ -> nil
      end

    {Enum.join(words, " "), author}
  end

  defp resolve_author("did:" <> _ = did), do: did

  defp resolve_author(handle) do
    Repo.one(from(a in S.Actor, where: a.handle == ^String.downcase(handle), select: a.did))
  end
end
