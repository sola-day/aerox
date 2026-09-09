defmodule Aerox.Blob.Store do
  @moduledoc """
  The blob-storage behaviour and its dispatching facade (DESIGN §4.4).

  Blob bytes live behind this behaviour; Postgres remains the only source of
  truth for what exists. An adapter is dumb, content-addressed byte storage
  scoped by DID, with three roots — permanent, temp, quarantine — laid out as
  `<root>/<did>/<cid>` on every adapter so a migration is a key-for-key copy.

  Every callback takes the `did` first and the adapter's `opts` (the keyword
  list from config, minus `:adapter`) last, so one adapter configuration serves
  every account.

  Rules every adapter must satisfy (enforced by `Aerox.Blob.StoreCase`):

  1. **Idempotent.** `put_permanent/4` of an existing CID is a no-op; `delete/3`
     of a missing CID is `:ok`.
  2. **Streaming both ways.** `put_temp/3` accepts an `Enumerable` of chunks;
     `stream/3` returns one.
  3. **Temp is not durable.** Only `make_permanent/4` promises persistence.
  4. **Key layout is `<did>/<cid>`** under the three roots.
  5. **No metadata.** The adapter stores bytes and answers "do I have these bytes".

  ## Facade

  The facade functions dispatch to the configured adapter:

      config :aerox, Aerox.Blob.Store, adapter: Aerox.Blob.Disk, root: "/var/lib/aerox/blobs"

  Each function also has a variant taking the adapter explicitly as
  `{module, opts}` as its first argument, so callers and tests never depend on
  global configuration: `Aerox.Blob.Store.get({Aerox.Blob.Disk, root: dir}, did, cid)`.

  ## Bodies

  A `body` is either iodata (a binary or an iolist) or an `Enumerable` of
  binary chunks (a `Stream`, a `File.Stream`, …). Binaries and lists are
  treated as iodata; anything else is enumerated.
  """

  alias Aerox.ATProto.CID

  @type did :: String.t()
  @type cid :: CID.t()
  @type key :: String.t()
  @type body :: iodata | Enumerable.t()
  @type opts :: keyword
  @type adapter :: {module, opts}

  # Two-phase write: stream to temp while the caller hashes; then commit under the CID.
  @callback put_temp(did, body, opts) :: {:ok, key} | {:error, term}
  @callback make_permanent(did, key, cid, opts) :: :ok | {:error, term}
  # Imports and migrations write straight to the permanent root.
  @callback put_permanent(did, cid, body, opts) :: :ok | {:error, term}
  @callback has_temp?(did, key, opts) :: boolean
  @callback has_stored?(did, cid, opts) :: boolean
  @callback get(did, cid, opts) :: {:ok, binary} | {:error, :not_found | term}
  @callback stream(did, cid, opts) :: {:ok, Enumerable.t()} | {:error, :not_found | term}
  # Takedown without deletion, and its reverse.
  @callback quarantine(did, cid, opts) :: :ok | {:error, term}
  @callback unquarantine(did, cid, opts) :: :ok | {:error, term}
  # Idempotent: a missing object is `:ok`.
  @callback delete(did, cid, opts) :: :ok | {:error, term}
  @callback delete_many(did, [cid], opts) :: :ok | {:error, term}
  # Account deletion: every object of the DID under every root.
  @callback delete_all(did, opts) :: :ok | {:error, term}
  # For the reaper: the CIDs of the DID's permanent objects.
  @callback list(did, keyword, opts) :: Enumerable.t()
  @callback presigned_url(did, cid, ttl :: pos_integer, opts) ::
              {:ok, String.t()} | :unsupported
  @optional_callbacks presigned_url: 4

  @doc """
  The configured adapter as `{module, opts}`.

  Raises if `config :aerox, Aerox.Blob.Store` has no `:adapter`.
  """
  @spec adapter() :: adapter
  def adapter do
    config = Application.get_env(:aerox, __MODULE__, [])

    case Keyword.pop(config, :adapter) do
      {nil, _} ->
        raise ArgumentError,
              "no blob store configured: set `config :aerox, Aerox.Blob.Store, adapter: ...`"

      {module, opts} when is_atom(module) ->
        {module, opts}
    end
  end

  @spec put_temp(did, body) :: {:ok, key} | {:error, term}
  def put_temp(did, body), do: put_temp(adapter(), did, body)

  @spec put_temp(adapter, did, body) :: {:ok, key} | {:error, term}
  def put_temp({mod, opts}, did, body), do: mod.put_temp(did, body, opts)

  @spec make_permanent(did, key, cid) :: :ok | {:error, term}
  def make_permanent(did, key, cid), do: make_permanent(adapter(), did, key, cid)

  @spec make_permanent(adapter, did, key, cid) :: :ok | {:error, term}
  def make_permanent({mod, opts}, did, key, cid), do: mod.make_permanent(did, key, cid, opts)

  @spec put_permanent(did, cid, body) :: :ok | {:error, term}
  def put_permanent(did, cid, body), do: put_permanent(adapter(), did, cid, body)

  @spec put_permanent(adapter, did, cid, body) :: :ok | {:error, term}
  def put_permanent({mod, opts}, did, cid, body), do: mod.put_permanent(did, cid, body, opts)

  @spec has_temp?(did, key) :: boolean
  def has_temp?(did, key), do: has_temp?(adapter(), did, key)

  @spec has_temp?(adapter, did, key) :: boolean
  def has_temp?({mod, opts}, did, key), do: mod.has_temp?(did, key, opts)

  @spec has_stored?(did, cid) :: boolean
  def has_stored?(did, cid), do: has_stored?(adapter(), did, cid)

  @spec has_stored?(adapter, did, cid) :: boolean
  def has_stored?({mod, opts}, did, cid), do: mod.has_stored?(did, cid, opts)

  @spec get(did, cid) :: {:ok, binary} | {:error, :not_found | term}
  def get(did, cid), do: get(adapter(), did, cid)

  @spec get(adapter, did, cid) :: {:ok, binary} | {:error, :not_found | term}
  def get({mod, opts}, did, cid), do: mod.get(did, cid, opts)

  @spec stream(did, cid) :: {:ok, Enumerable.t()} | {:error, :not_found | term}
  def stream(did, cid), do: stream(adapter(), did, cid)

  @spec stream(adapter, did, cid) :: {:ok, Enumerable.t()} | {:error, :not_found | term}
  def stream({mod, opts}, did, cid), do: mod.stream(did, cid, opts)

  @spec quarantine(did, cid) :: :ok | {:error, term}
  def quarantine(did, cid), do: quarantine(adapter(), did, cid)

  @spec quarantine(adapter, did, cid) :: :ok | {:error, term}
  def quarantine({mod, opts}, did, cid), do: mod.quarantine(did, cid, opts)

  @spec unquarantine(did, cid) :: :ok | {:error, term}
  def unquarantine(did, cid), do: unquarantine(adapter(), did, cid)

  @spec unquarantine(adapter, did, cid) :: :ok | {:error, term}
  def unquarantine({mod, opts}, did, cid), do: mod.unquarantine(did, cid, opts)

  @spec delete(did, cid) :: :ok | {:error, term}
  def delete(did, cid), do: delete(adapter(), did, cid)

  @spec delete(adapter, did, cid) :: :ok | {:error, term}
  def delete({mod, opts}, did, cid), do: mod.delete(did, cid, opts)

  @spec delete_many(did, [cid]) :: :ok | {:error, term}
  def delete_many(did, cids), do: delete_many(adapter(), did, cids)

  @spec delete_many(adapter, did, [cid]) :: :ok | {:error, term}
  def delete_many({mod, opts}, did, cids), do: mod.delete_many(did, cids, opts)

  @spec delete_all(did) :: :ok | {:error, term}
  def delete_all(did), do: delete_all(adapter(), did)

  @spec delete_all(adapter, did) :: :ok | {:error, term}
  def delete_all({mod, opts}, did), do: mod.delete_all(did, opts)

  @spec list(did) :: Enumerable.t()
  def list(did) when is_binary(did), do: list(adapter(), did, [])

  @spec list(did, keyword) :: Enumerable.t()
  @spec list(adapter, did) :: Enumerable.t()
  def list(did, list_opts) when is_binary(did) and is_list(list_opts),
    do: list(adapter(), did, list_opts)

  def list({mod, opts}, did) when is_binary(did), do: list({mod, opts}, did, [])

  @spec list(adapter, did, keyword) :: Enumerable.t()
  def list({mod, opts}, did, list_opts), do: mod.list(did, list_opts, opts)

  @spec presigned_url(did, cid, pos_integer) :: {:ok, String.t()} | :unsupported
  def presigned_url(did, cid, ttl), do: presigned_url(adapter(), did, cid, ttl)

  @doc "`:unsupported` when the adapter does not implement `presigned_url/4`."
  @spec presigned_url(adapter, did, cid, pos_integer) :: {:ok, String.t()} | :unsupported
  def presigned_url({mod, opts}, did, cid, ttl) do
    if function_exported?(mod, :presigned_url, 4) do
      mod.presigned_url(did, cid, ttl, opts)
    else
      :unsupported
    end
  end
end
