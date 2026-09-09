defmodule Aerox.Labeler.Labels do
  @moduledoc """
  Labels (DESIGN §17.1): created labels are **signed** with the labeler key
  over the DAG-CBOR of the unsigned label exactly as upstream
  `@atproto/label` `signLabel` does (`ver`, `src`, `uri`, `cid`, `val`,
  `neg` only when true, `cts`, `exp`; absent fields omitted), stored in
  `labeler.label` — one row per `(src, uri, cid, val)`, replaced on
  re-application or negation as ozone's `createLabels` upsert does — and
  sequenced as one `#labels` event for `subscribeLabels`. `query/1` serves
  `com.atproto.label.queryLabels` with ozone's semantics: `*`-suffix
  prefix patterns, `sources`, `limit`, an `id` cursor.
  """
  import Ecto.Query
  alias Aerox.ATProto.{Bytes, Crypto, DagCBOR, Syntax}
  alias Aerox.Labeler.{Config, Repo, Sequencer}
  alias Aerox.Labeler.Schema.Label

  @type attrs :: %{
          required(:uri) => String.t(),
          optional(:cid) => String.t() | nil,
          required(:val) => String.t(),
          optional(:neg) => boolean,
          optional(:exp) => DateTime.t() | nil,
          optional(:cts) => DateTime.t()
        }

  # ------------------------------------------------------------ signing

  @doc "The wire form of a label without its signature (the bytes that are signed)."
  @spec unsigned(map) :: map
  def unsigned(label) do
    label = if is_struct(label), do: Map.from_struct(label), else: label

    %{
      "ver" => label[:ver] || 1,
      "src" => label.src,
      "uri" => label.uri,
      "cid" => blank_to_nil(label[:cid]),
      "val" => label.val,
      "neg" => if(label[:neg] == true, do: true),
      "cts" => datetime(label.cts),
      "exp" => label[:exp] && datetime(label.exp)
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  @doc "Signs a label (a map with atom keys) with the labeler key; returns the signature bytes."
  @spec sign(map, Crypto.Keypair.t()) :: binary
  def sign(label, keypair \\ Config.signing_keypair()),
    do: Crypto.sign(keypair, DagCBOR.encode(unsigned(label)))

  @doc "Verifies a wire-form label (string keys, `sig` as `Bytes`) against a `did:key`."
  @spec valid_signature?(map, String.t()) :: boolean
  def valid_signature?(%{"sig" => %Bytes{data: sig}} = wire, did_key) do
    bytes = wire |> Map.delete("sig") |> DagCBOR.encode()
    Crypto.verify_did_sig(did_key, bytes, sig)
  end

  def valid_signature?(_, _), do: false

  @doc "A stored row (or attrs with `src`/`sig`) in `com.atproto.label.defs#label` wire form."
  @spec to_wire(map) :: map
  def to_wire(label) do
    label = if is_struct(label), do: Map.from_struct(label), else: label
    base = unsigned(label)
    if sig = label[:sig], do: Map.put(base, "sig", Bytes.new(sig)), else: base
  end

  # ------------------------------------------------------------- writes

  @doc "Signs, stores and sequences one label by this labeler."
  @spec create(attrs) :: {:ok, Label.t()} | {:error, term}
  def create(attrs) do
    case create_many([attrs]) do
      {:ok, [label]} -> {:ok, label}
      {:error, _} = e -> e
    end
  end

  @doc "Signs, stores and sequences several labels as one `#labels` event."
  @spec create_many([attrs]) :: {:ok, [Label.t()]} | {:error, term}
  def create_many([]), do: {:ok, []}

  def create_many(attrs_list) do
    src = Config.did() || raise("labeler DID not configured")
    keypair = Config.signing_keypair()
    # cts is signed as an ISO string with millisecond precision: store it that way too
    now = DateTime.utc_now() |> to_millis()

    labels =
      Enum.map(attrs_list, fn attrs ->
        label = %{
          src: src,
          uri: attrs.uri,
          cid: attrs[:cid] || "",
          val: attrs.val,
          neg: attrs[:neg] == true,
          cts: (attrs[:cts] || now) |> to_millis(),
          exp: attrs[:exp] && to_millis(attrs.exp),
          ver: 1
        }

        Map.put(label, :sig, sign(label, keypair))
      end)

    with {:ok, seq} <- Sequencer.sequence_labels(src, Enum.map(labels, &to_wire/1)) do
      rows =
        Repo.insert_all(
          Label,
          Enum.map(labels, &Map.put(&1, :seq, seq)),
          on_conflict: {:replace, [:neg, :cts, :exp, :sig, :ver, :seq]},
          conflict_target: [:src, :uri, :cid, :val],
          returning: true
        )
        |> elem(1)

      {:ok, rows}
    end
  end

  @doc "Negates a label: a `neg: true` label for the same subject and value."
  @spec negate(String.t(), String.t() | nil, String.t()) :: {:ok, Label.t()} | {:error, term}
  def negate(uri, cid, val), do: create(%{uri: uri, cid: cid, val: val, neg: true})

  @doc "Is `val` currently applied (not negated, not expired) to the subject by this labeler?"
  @spec applied?(String.t(), String.t()) :: boolean
  def applied?(uri, val) do
    now = DateTime.utc_now()
    src = Config.did()

    Repo.exists?(
      from(l in Label,
        where:
          l.src == ^src and l.uri == ^uri and l.val == ^val and l.neg == false and
            (is_nil(l.exp) or l.exp > ^now)
      )
    )
  end

  # ------------------------------------------------------------- queries

  @doc """
  `com.atproto.label.queryLabels`: `uri_patterns` (exact, or `prefix*`; a
  lone `*` matches everything), optional `sources`, `limit` (default 50),
  and the previous page's `cursor` (a label id). Returns `{labels, cursor}`.
  """
  @spec query(map) :: {:ok, {[Label.t()], String.t() | nil}} | {:error, String.t()}
  def query(params) do
    patterns = params[:uri_patterns] || params["uriPatterns"] || []
    sources = params[:sources] || params["sources"]
    limit = params[:limit] || params["limit"] || 50
    cursor = params[:cursor] || params["cursor"]

    with {:ok, q} <- pattern_query(patterns),
         {:ok, q} <- cursor_query(q, cursor) do
      q = if sources && sources != [], do: where(q, [l], l.src in ^sources), else: q
      rows = q |> order_by([l], asc: l.id) |> limit(^limit) |> Repo.all()
      next = if rows == [], do: nil, else: Integer.to_string(List.last(rows).id)
      {:ok, {rows, next}}
    end
  end

  defp pattern_query(patterns) do
    if "*" in patterns do
      {:ok, from(l in Label)}
    else
      Enum.reduce_while(patterns, {:ok, false}, fn pattern, {:ok, acc} ->
        case String.split(pattern, "*", parts: 2) do
          [_exact] ->
            {:cont, {:ok, dynamic([l], ^acc or l.uri == ^pattern)}}

          [prefix, ""] ->
            like =
              String.replace(prefix, ["%", "_"], fn
                "%" -> ""
                "_" -> "\\_"
              end) <> "%"

            {:cont, {:ok, dynamic([l], ^acc or like(l.uri, ^like))}}

          _ ->
            {:halt, {:error, "invalid pattern: #{pattern}"}}
        end
      end)
      |> case do
        {:ok, filter} -> {:ok, from(l in Label, where: ^filter)}
        {:error, _} = e -> e
      end
    end
  end

  defp cursor_query(q, nil), do: {:ok, q}
  defp cursor_query(q, ""), do: {:ok, q}

  defp cursor_query(q, cursor) do
    case Integer.parse(cursor) do
      {id, ""} -> {:ok, where(q, [l], l.id > ^id)}
      _ -> {:error, "invalid cursor"}
    end
  end

  @doc "Every current label on a subject by this labeler."
  def for_subject(uri) do
    Repo.all(from(l in Label, where: l.uri == ^uri, order_by: [asc: l.id]))
  end

  # ------------------------------------------------------------- helpers

  # millisecond precision, stored with the column's microsecond type
  defp to_millis(%DateTime{microsecond: {us, _}} = dt),
    do: %{dt | microsecond: {div(us, 1000) * 1000, 6}}

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v
  defp datetime(%DateTime{} = dt), do: Syntax.format_datetime(dt)
  defp datetime(str) when is_binary(str), do: str
end
