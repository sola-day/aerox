defmodule Aerox.PDS.Sequencer.Events do
  @moduledoc """
  The four firehose event bodies (DESIGN §5, upstream `sequencer/events.ts`)
  as DAG-CBOR-ready maps, and their decoding back from `repo_seq` rows into
  `com.atproto.sync.subscribeRepos` frames.
  """
  alias Aerox.ATProto.{Bytes, CAR, CID, DagCBOR, Syntax}

  @type event_type :: :append | :sync | :identity | :account
  @type row :: %{did: String.t(), event_type: String.t(), event: binary}

  @doc "A `#commit` event body from a `Aerox.ATProto.Repo.commit_data/0`."
  @spec commit(String.t(), map) :: row
  def commit(did, commit_data) do
    blocks = Map.merge(commit_data.new_blocks, commit_data.relevant_blocks)
    car = CAR.encode(commit_data.cid, Map.to_list(blocks))

    body = %{
      "repo" => did,
      "commit" => commit_data.cid,
      "rev" => commit_data.rev,
      "since" => commit_data.since,
      "blocks" => Bytes.new(car),
      "ops" =>
        Enum.map(commit_data.ops, fn op ->
          %{"action" => Atom.to_string(op.action), "path" => op.path, "cid" => op.cid}
          |> then(&if(op.prev, do: Map.put(&1, "prev", op.prev), else: &1))
        end),
      "rebase" => false,
      "tooBig" => false,
      "blobs" => []
    }

    body =
      if commit_data.prev_data, do: Map.put(body, "prevData", commit_data.prev_data), else: body

    %{did: did, event_type: "append", event: DagCBOR.encode(body)}
  end

  @doc "A `#sync` event: the commit block alone, as a CAR with the commit as root."
  @spec sync(String.t(), CID.t(), String.t(), binary) :: row
  def sync(did, commit_cid, rev, commit_bytes) do
    car = CAR.encode(commit_cid, [{commit_cid, commit_bytes}])

    %{
      did: did,
      event_type: "sync",
      event: DagCBOR.encode(%{"did" => did, "rev" => rev, "blocks" => Bytes.new(car)})
    }
  end

  @spec identity(String.t(), String.t() | nil) :: row
  def identity(did, handle) do
    body = if handle, do: %{"did" => did, "handle" => handle}, else: %{"did" => did}
    %{did: did, event_type: "identity", event: DagCBOR.encode(body)}
  end

  @statuses ~w(active takendown suspended deleted deactivated)

  @spec account(String.t(), String.t()) :: row
  def account(did, "active"),
    do: %{
      did: did,
      event_type: "account",
      event: DagCBOR.encode(%{"did" => did, "active" => true})
    }

  def account(did, status) when status in @statuses,
    do: %{
      did: did,
      event_type: "account",
      event: DagCBOR.encode(%{"did" => did, "active" => false, "status" => status})
    }

  @doc "A stored row → `{frame_type, body_with_seq_and_time}`."
  @spec to_frame(map) :: {String.t(), map}
  def to_frame(%{seq: seq, event_type: type, event: bytes, sequenced_at: at}) do
    {:ok, body} = DagCBOR.decode(bytes)

    t =
      case type do
        "append" -> "#commit"
        "sync" -> "#sync"
        "identity" -> "#identity"
        "account" -> "#account"
      end

    {t, body |> Map.put("seq", seq) |> Map.put("time", Syntax.format_datetime(at))}
  end
end
