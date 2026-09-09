defmodule Aerox.Labeler.Reports do
  @moduledoc """
  Report intake (DESIGN §17.2): `com.atproto.moderation.createReport`
  arrives at the PDS, is proxied to this service with a service JWT for the
  reporter, and is stored in `labeler.mod_report`. Upstream
  `createReport.ts` validates the subject shape and the reason type; the
  lexicon validation of the input does that here.
  """
  import Ecto.Query
  alias Aerox.ATProto.Syntax
  alias Aerox.Labeler.Repo
  alias Aerox.Labeler.Schema.ModReport
  alias Aerox.Labeler.Subject

  @type attrs :: %{
          required(:subject) => map,
          required(:reason_type) => String.t(),
          optional(:reason) => String.t() | nil,
          required(:reported_by) => String.t()
        }

  @spec create(attrs) :: {:ok, ModReport.t()} | {:error, term}
  def create(attrs) do
    with {:ok, subject} <- Subject.normalize(attrs.subject) do
      Repo.insert(%ModReport{
        subject: subject,
        reason_type: attrs.reason_type,
        reason: attrs[:reason],
        reported_by: attrs.reported_by,
        created_at: DateTime.utc_now()
      })
    end
  end

  @spec get(integer) :: ModReport.t() | nil
  def get(id), do: Repo.get(ModReport, id)

  @doc "Reports, newest first; `subject:` (a DID or AT-URI) filters, `cursor:` is the previous page's last id."
  @spec list(keyword) :: {[ModReport.t()], String.t() | nil}
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    q = from(r in ModReport, order_by: [desc: r.id], limit: ^limit)
    q = Subject.filter(q, Keyword.get(opts, :subject))

    q =
      case Keyword.get(opts, :cursor) do
        nil -> q
        "" -> q
        cursor -> where(q, [r], r.id < ^String.to_integer(cursor))
      end

    rows = Repo.all(q)
    next = if length(rows) == limit, do: Integer.to_string(List.last(rows).id)
    {rows, next}
  end

  @doc "The `createReport` output shape."
  def view(%ModReport{} = r) do
    %{
      "id" => r.id,
      "reasonType" => r.reason_type,
      "reason" => r.reason,
      "subject" => r.subject,
      "reportedBy" => r.reported_by,
      "createdAt" => Syntax.format_datetime(r.created_at)
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end
end

defmodule Aerox.Labeler.Subject do
  @moduledoc """
  Moderation subjects, the union `com.atproto.admin.defs#repoRef`
  (an account) | `com.atproto.repo.strongRef` (a record) |
  `com.atproto.admin.defs#repoBlobRef` (a blob), stored as the JSON map
  with its `$type`.
  """
  import Ecto.Query
  alias Aerox.ATProto.Syntax

  @repo_ref "com.atproto.admin.defs#repoRef"
  @strong_ref "com.atproto.repo.strongRef"
  @blob_ref "com.atproto.admin.defs#repoBlobRef"

  def repo_ref, do: @repo_ref
  def strong_ref, do: @strong_ref
  def blob_ref, do: @blob_ref

  @doc "Validates and canonicalises a subject map."
  @spec normalize(map) :: {:ok, map} | {:error, String.t()}
  def normalize(%{"$type" => @repo_ref, "did" => did}) when is_binary(did) do
    if Syntax.valid_did?(did),
      do: {:ok, %{"$type" => @repo_ref, "did" => did}},
      else: {:error, "Invalid subject: not a DID"}
  end

  def normalize(%{"$type" => @strong_ref, "uri" => uri} = s) when is_binary(uri) do
    case Syntax.parse_at_uri(uri) do
      {:ok, %{authority: "did:" <> _, collection: c, rkey: r}}
      when is_binary(c) and is_binary(r) ->
        {:ok,
         %{"$type" => @strong_ref, "uri" => uri, "cid" => s["cid"]}
         |> Enum.reject(fn {_, v} -> is_nil(v) end)
         |> Map.new()}

      _ ->
        {:error, "Invalid subject: not a record AT-URI"}
    end
  end

  def normalize(%{"$type" => @blob_ref, "did" => did, "cid" => cid})
      when is_binary(did) and is_binary(cid),
      do: {:ok, %{"$type" => @blob_ref, "did" => did, "cid" => cid}}

  def normalize(_), do: {:error, "Invalid subject"}

  @doc "The kind of a subject."
  @spec kind(map) :: :account | :record | :blob
  def kind(%{"$type" => @repo_ref}), do: :account
  def kind(%{"$type" => @strong_ref}), do: :record
  def kind(%{"$type" => @blob_ref}), do: :blob

  @doc "The DID a subject belongs to."
  @spec did(map) :: String.t()
  def did(%{"$type" => @strong_ref, "uri" => uri}) do
    {:ok, %{authority: did}} = Syntax.parse_at_uri(uri)
    did
  end

  def did(%{"did" => did}), do: did

  @doc "The label subject URI: the DID for an account, the AT-URI for a record."
  @spec label_uri(map) :: String.t()
  def label_uri(%{"$type" => @strong_ref, "uri" => uri}), do: uri
  def label_uri(%{"did" => did}), do: did

  @doc "Filters a query on a JSON `subject` column by DID or AT-URI."
  def filter(q, nil), do: q

  def filter(q, "at://" <> _ = uri),
    do: where(q, [r], fragment("?->>'uri' = ?", r.subject, ^uri))

  def filter(q, did), do: where(q, [r], fragment("?->>'did' = ?", r.subject, ^did))
end
