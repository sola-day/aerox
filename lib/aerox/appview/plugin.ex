defmodule Aerox.AppView.Plugin do
  @moduledoc """
  One record type's indexing rules (DESIGN §15.2; upstream
  `indexing/plugins/*` + `RecordProcessor`). A plugin owns its table's
  insert and delete, says which existing record a new one duplicates, lists
  the notifications an insert or delete implies, and maintains aggregates.
  `Aerox.AppView.Indexing` drives them inside one transaction per record.

  Records reach plugins already validated against the vendored lexicon
  (`Aerox.ATProto.Lexicon`); an invalid record is written to `record` only.
  """
  alias Aerox.AppView.Repo

  @type row :: map
  @type notif :: %{
          did: String.t(),
          author: String.t(),
          record_uri: String.t(),
          record_cid: String.t(),
          reason: String.t(),
          reason_subject: String.t() | nil,
          sort_at: DateTime.t()
        }

  @doc "The record collection NSID."
  @callback collection() :: String.t()

  @doc "Insert the indexed row(s); `nil` when the row already existed."
  @callback insert(
              uri :: String.t(),
              cid :: String.t(),
              record :: map,
              indexed_at :: DateTime.t()
            ) ::
              row | nil

  @doc "The URI of an already-indexed record this one duplicates (e.g. a second like of the same post), or nil."
  @callback find_duplicate(uri :: String.t(), record :: map) :: String.t() | nil

  @doc "Delete the indexed row(s); returns the deleted row or nil."
  @callback delete(uri :: String.t()) :: row | nil

  @callback notifs_for_insert(row) :: [notif]
  @callback notifs_for_delete(deleted :: row, replaced_by :: row | nil) ::
              %{notifs: [notif], to_delete: [String.t()]}
  @callback update_aggregates(row) :: :ok

  @optional_callbacks find_duplicate: 2,
                      notifs_for_insert: 1,
                      notifs_for_delete: 2,
                      update_aggregates: 1

  defmacro __using__(_) do
    quote do
      @behaviour Aerox.AppView.Plugin
      import Ecto.Query
      import Aerox.AppView.Plugin.Helpers
      alias Aerox.AppView.Repo
      alias Aerox.AppView.Schema

      def find_duplicate(_uri, _record), do: nil
      def notifs_for_insert(_row), do: []

      def notifs_for_delete(deleted, replaced_by),
        do: %{notifs: [], to_delete: if(replaced_by, do: [], else: [deleted.uri])}

      def update_aggregates(_row), do: :ok

      defoverridable find_duplicate: 2,
                     notifs_for_insert: 1,
                     notifs_for_delete: 2,
                     update_aggregates: 1
    end
  end

  @doc "Notification for `did` about `record` (a row with uri/cid/creator/sort_at)."
  def notif(did, row, reason, reason_subject) do
    %{
      did: did,
      author: row.creator,
      record_uri: row.uri,
      record_cid: row.cid,
      reason: reason,
      reason_subject: reason_subject,
      sort_at: row.sort_at
    }
  end

  @doc "Upsert `%{count_field => count}` on an aggregate table row."
  def set_aggregate(schema, key_field, key, field, count) do
    Repo.insert_all(schema, [%{key_field => key, field => count}],
      on_conflict: {:replace, [field]},
      conflict_target: key_field
    )

    :ok
  end

  defmodule Helpers do
    @moduledoc false
    alias Aerox.ATProto.Syntax

    @doc "The DID (authority) of an at-uri."
    def uri_did(uri) do
      case Syntax.parse_at_uri(uri) do
        {:ok, %{authority: did}} -> did
        _ -> nil
      end
    end

    @doc "The collection of an at-uri."
    def uri_collection(uri) do
      case Syntax.parse_at_uri(uri) do
        {:ok, %{collection: c}} -> c
        _ -> nil
      end
    end

    def uri_rkey(uri) do
      case Syntax.parse_at_uri(uri) do
        {:ok, %{rkey: r}} -> r
        _ -> nil
      end
    end

    @doc "Upstream `normalizeDatetimeAlways`: a parsable datetime (at microsecond precision), else the epoch."
    def created_at(value) do
      case value && Syntax.parse_datetime(value) do
        {:ok, dt} -> usec(dt)
        _ -> ~U[1970-01-01 00:00:00.000000Z]
      end
    end

    @doc "A DateTime at the microsecond precision Ecto's usec fields require."
    def usec(%DateTime{microsecond: {us, _}} = dt), do: %{dt | microsecond: {us, 6}}

    @doc "A blob ref's CID string (`{$link}`/CID struct/legacy `{cid}`)."
    def blob_cid(%{"ref" => %Aerox.ATProto.CID{} = cid}), do: Aerox.ATProto.CID.to_string(cid)
    def blob_cid(%{"ref" => %{"$link" => link}}), do: link
    def blob_cid(%{"cid" => cid}) when is_binary(cid), do: cid
    def blob_cid(_), do: nil

    @doc "CID value (struct or string) as a string."
    def cid_string(%Aerox.ATProto.CID{} = cid), do: Aerox.ATProto.CID.to_string(cid)
    def cid_string(cid) when is_binary(cid), do: cid
    def cid_string(_), do: nil

    @doc "Insert one row; returns the row (generated columns included) or nil when any unique constraint already holds it (upstream `onConflict doNothing`)."
    def insert_row(schema, attrs) do
      case Aerox.AppView.Repo.insert_all(schema, [attrs], on_conflict: :nothing, returning: true) do
        {1, [row]} -> row
        _ -> nil
      end
    end

    @doc "Delete rows by a where clause; returns the first deleted row or nil."
    def delete_rows(schema, clauses) do
      import Ecto.Query

      query =
        Enum.reduce(clauses, from(r in schema), fn {k, v}, q ->
          where(q, [r], field(r, ^k) == ^v)
        end)

      case Aerox.AppView.Repo.delete_all(select(query, [r], r)) do
        {n, [row | _]} when n > 0 -> row
        _ -> nil
      end
    end

    @doc "The earlier of two datetimes (upstream sortAt = min(createdAt, indexedAt))."
    def min_dt(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

    @doc "A count query's result."
    def count(query), do: Aerox.AppView.Repo.aggregate(query, :count)
  end
end
