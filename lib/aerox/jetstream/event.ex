defmodule Aerox.Jetstream.Event do
  @moduledoc """
  One Jetstream row (`segment.Event`): an ingestion sequence number, when it was
  witnessed and (optionally) the operator-imported display time, the kind, and
  the columns a block stores. `payload` is DAG-CBOR: the record for a
  create/update/resync row, the upstream firehose event for identity, account
  and sync rows, empty for a delete.
  """

  @kinds %{create: 1, update: 2, delete: 3, identity: 4, account: 5, sync: 6, create_resync: 7}
  @by_code Map.new(@kinds, fn {k, v} -> {v, k} end)

  defstruct seq: 0,
            witnessed_at: 0,
            indexed_at: 0,
            kind: :create,
            did: "",
            collection: "",
            rkey: "",
            rev: "",
            payload: ""

  @type kind :: :create | :update | :delete | :identity | :account | :sync | :create_resync
  @type t :: %__MODULE__{
          seq: non_neg_integer,
          witnessed_at: integer,
          indexed_at: integer,
          kind: kind,
          did: String.t(),
          collection: String.t(),
          rkey: String.t(),
          rev: String.t(),
          payload: binary
        }

  def kind_code(kind), do: Map.fetch!(@kinds, kind)
  def kind_from_code(code), do: Map.fetch(@by_code, code)

  @doc "Commit-shaped rows (rendered as `commit` events)."
  def commit?(%__MODULE__{kind: k}), do: k in [:create, :update, :delete, :create_resync]

  @doc "Rows that carry the record bytes of a repo path."
  def materialization?(%__MODULE__{kind: k}), do: k in [:create, :update, :create_resync]

  @doc "The time shown to subscribers: the imported display time, else when it was witnessed."
  def display_time_us(%__MODULE__{indexed_at: 0, witnessed_at: w}), do: w
  def display_time_us(%__MODULE__{indexed_at: i}), do: i

  @doc "The DID-level marker sentinel a block's collection index records for marker rows."
  def sentinel(%__MODULE__{kind: :account}), do: "$account"
  def sentinel(%__MODULE__{kind: :identity}), do: "$identity"
  def sentinel(%__MODULE__{kind: :sync}), do: "$sync"
  def sentinel(_), do: nil
end
