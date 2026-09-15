defmodule Aerox.Relay.Collections do
  @moduledoc """
  The collection directory (Sync spec; indigo `collectiondir`): which DIDs have
  records in which collection, served by `com.atproto.sync.listReposByCollection`.

  It is kept from two sources. Every verified `#commit` adds the collections of
  its `create` ops. An account's pre-existing collections are read once from
  its PDS with `com.atproto.repo.describeRepo` (`crawl/1`), by
  `Aerox.Relay.CollectionCrawler`, which also re-reads them after a `#sync`.
  A deleted account leaves the directory.

  Like indigo's, the directory answers "which repos may have records here":
  a DID stays listed after its last record in a collection is deleted, until
  the next crawl of that account replaces its set.
  """
  import Ecto.Query
  alias Aerox.Identity.HTTP
  alias Aerox.Relay.{Accounts, Config, Hosts, Repo}
  alias Aerox.Relay.Schema.{Account, RepoCollection}

  @max_limit 2000

  @doc "Adds the collections created by a commit's ops."
  @spec note_ops(String.t(), list) :: :ok
  def note_ops(did, ops) when is_list(ops) do
    ops
    |> Enum.filter(&(is_map(&1) and &1["action"] == "create" and is_binary(&1["path"])))
    |> Enum.map(&(&1["path"] |> String.split("/", parts: 2) |> hd()))
    |> add(did)
  end

  def note_ops(_, _), do: :ok

  @doc "Records that `did` has records in each of `collections`."
  def add([], _did), do: :ok

  def add(collections, did) do
    now = DateTime.utc_now()
    rows = for c <- Enum.uniq(collections), do: %{collection: c, did: did, inserted_at: now}

    Repo.insert_all(RepoCollection, rows,
      on_conflict: :nothing,
      conflict_target: [:collection, :did]
    )

    :ok
  end

  @doc "An account that no longer exists has no collections."
  def remove_account(did) do
    Repo.delete_all(from(r in RepoCollection, where: r.did == ^did))
    :ok
  end

  @doc "A page of DIDs with records in `collection`, oldest first sight first."
  @spec list(String.t(), pos_integer | nil, String.t() | nil) ::
          {:ok, %{repos: [String.t()], cursor: String.t() | nil}} | {:error, :invalid_cursor}
  def list(collection, limit, cursor) do
    limit = min(limit || 500, @max_limit)

    with {:ok, after_id} <- parse_cursor(cursor) do
      rows =
        from(r in RepoCollection,
          join: a in Account,
          on: a.did == r.did,
          where: r.collection == ^collection and r.id > ^after_id,
          where: a.status == "active" and a.upstream_status == "active",
          order_by: [asc: r.id],
          limit: ^limit,
          select: {r.id, r.did}
        )
        |> Repo.all()

      next = if length(rows) == limit, do: rows |> List.last() |> elem(0) |> Integer.to_string()
      {:ok, %{repos: Enum.map(rows, &elem(&1, 1)), cursor: next}}
    end
  end

  defp parse_cursor(nil), do: {:ok, 0}
  defp parse_cursor(""), do: {:ok, 0}

  defp parse_cursor(c) do
    case Integer.parse(c) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :invalid_cursor}
    end
  end

  @doc """
  Reads the account's collections from its PDS (`describeRepo`) and makes them
  the account's set, then marks the account crawled.
  """
  @spec crawl(String.t()) :: :ok | {:error, term}
  def crawl(did) do
    with %Account{} = acc <- Accounts.get(did) || {:error, :unknown_account},
         %{} = host <- Hosts.get_by_id(acc.host_id) || {:error, :unknown_host},
         started = DateTime.utc_now(),
         {:ok, collections} <- describe_repo(Hosts.http_url(host), did) do
      Repo.transaction(fn ->
        # rows a live commit added while describeRepo was in flight stay
        Repo.delete_all(
          from(r in RepoCollection,
            where: r.did == ^did and r.collection not in ^collections and r.inserted_at < ^started
          )
        )

        add(collections, did)

        Repo.update_all(from(a in Account, where: a.uid == ^acc.uid),
          set: [collections_crawled_at: DateTime.utc_now()]
        )
      end)

      :ok
    end
  end

  @doc "Accounts never crawled, oldest first."
  def uncrawled(limit) do
    from(a in Account,
      where: is_nil(a.collections_crawled_at) and a.upstream_status == "active",
      order_by: [asc: a.uid],
      limit: ^limit,
      select: a.did
    )
    |> Repo.all()
  end

  defp describe_repo(pds, did) do
    url = pds <> "/xrpc/com.atproto.repo.describeRepo?repo=" <> URI.encode_www_form(did)

    opts =
      [timeout: 15_000, max_bytes: 1_000_000, allow_private: Config.allow_insecure_hosts?()] ++
        Keyword.take(Application.get_env(:aerox, Aerox.Relay.HostChecker, []), [
          :plug,
          :allow_private
        ])

    case HTTP.get(url, opts) do
      {:ok, 200, _, body} ->
        case Jason.decode(body) do
          {:ok, %{"collections" => cs}} when is_list(cs) ->
            {:ok, Enum.filter(cs, &Aerox.ATProto.Syntax.valid_nsid?/1)}

          _ ->
            {:error, :invalid_response}
        end

      {:ok, status, _, _} ->
        {:error, {:http, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
