defmodule Aerox.PDS.Lexicons do
  @moduledoc """
  Lexicons the PDS needs at run time that it did not ship with — above all
  OAuth permission sets (Permission spec, "Permission Sets": authorization
  servers "resolve, authenticate, and process permission-sets dynamically").

  A lookup takes the vendored registry first, then this table, refreshed
  through `Aerox.Identity.LexiconResolver` once an entry is older than five
  minutes (upstream `LEXICON_REFRESH_FREQUENCY`). A refresh that fails keeps
  the last document that resolved (upstream `LexiconGetter`), and a lexicon
  that has never resolved is remembered as missing for the same five minutes
  rather than fetched again for every request.
  """
  alias Aerox.ATProto.Lexicon
  alias Aerox.Identity.LexiconResolver
  alias Aerox.PDS.{Config, Repo}
  alias Aerox.PDS.Schema.Lexicon, as: Row

  @refresh_after_s 300

  @type resolved :: %{uri: String.t() | nil, cid: String.t() | nil, doc: map}

  @doc "The lexicon document for an NSID (`id`, `defs`, …), vendored or resolved."
  @spec get(String.t(), keyword) :: {:ok, resolved} | {:error, :not_found}
  def get(nsid, opts \\ []) do
    case Map.fetch(Lexicon.default_registry().docs, nsid) do
      {:ok, doc} -> {:ok, %{uri: nil, cid: nil, doc: doc}}
      :error -> resolved(nsid, opts)
    end
  end

  @doc "The `permission-set` main def for an NSID, or nil."
  @spec permission_set(String.t()) :: map | nil
  def permission_set(nsid) do
    case get(nsid) do
      {:ok, %{doc: %{"defs" => %{"main" => %{"type" => "permission-set"} = def}}}} -> def
      _ -> nil
    end
  end

  defp resolved(nsid, opts) do
    now = DateTime.utc_now()
    row = Repo.get(Row, nsid)
    fresh? = row != nil and DateTime.diff(now, row.updated_at) < @refresh_after_s

    row =
      if fresh? and not Keyword.get(opts, :force, false),
        do: row,
        else: refresh(nsid, row, now)

    case row do
      %Row{record: %{} = record} = r ->
        {:ok, %{uri: r.uri, cid: r.cid, doc: Map.delete(record, "$type")}}

      _ ->
        {:error, :not_found}
    end
  end

  defp refresh(nsid, row, now) do
    result = LexiconResolver.resolve(nsid, plc_url: Config.plc_url())

    attrs =
      case result do
        {:ok, %{uri: uri, cid: cid, record: record}} ->
          %{
            uri: uri,
            cid: cid,
            record: Aerox.ATProto.Data.to_json(record),
            last_succeeded_at: now
          }

        {:error, _} ->
          # keep the last good document, if there was one
          %{
            uri: row && row.uri,
            cid: row && row.cid,
            record: row && row.record,
            last_succeeded_at: row && row.last_succeeded_at
          }
      end

    Repo.insert_all(
      Row,
      [
        Map.merge(attrs, %{
          nsid: nsid,
          updated_at: now,
          created_at: (row && row.created_at) || now
        })
      ],
      on_conflict: {:replace, [:uri, :cid, :record, :last_succeeded_at, :updated_at]},
      conflict_target: :nsid
    )

    Repo.get(Row, nsid)
  end
end
