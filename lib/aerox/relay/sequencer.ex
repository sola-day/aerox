defmodule Aerox.Relay.Sequencer do
  @moduledoc """
  The Relay's own sequencer over `relay.repo_seq` (DESIGN §19): verified
  upstream events are re-sequenced here with the Relay's `seq`, then fanned
  out on topic `"relay:firehose"`. The stored `event` is the upstream body
  minus its `seq`; `to_frame/1` puts the Relay's seq in.
  """
  alias Aerox.ATProto.{DagCBOR, Syntax}
  alias Aerox.Relay.Repo
  alias Aerox.Relay.Schema.RepoSeq

  @topic "relay:firehose"
  def topic, do: @topic

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}

  def start_link(opts \\ []) do
    Aerox.Sequencer.start_link(
      name: Keyword.get(opts, :name, __MODULE__),
      repo: Repo,
      schema: RepoSeq,
      topic: @topic,
      unboxed: Application.get_env(:aerox, __MODULE__, [])[:unboxed] || false
    )
  end

  @doc "Re-sequence a verified event: `type` is `#commit`/`#sync`/`#identity`/`#account`, `body` the decoded map."
  @spec emit(String.t(), String.t(), map, GenServer.server()) ::
          {:ok, [pos_integer]} | {:error, term}
  def emit(did, type, body, server \\ __MODULE__) do
    row = %{
      did: did,
      event_type: event_type(type),
      event: DagCBOR.encode(Map.delete(body, "seq"))
    }

    Aerox.Sequencer.sequence(server, [row])
  end

  defp event_type("#commit"), do: "append"
  defp event_type("#sync"), do: "sync"
  defp event_type("#identity"), do: "identity"
  defp event_type("#account"), do: "account"

  # Source callbacks (AeroxWeb.Sockets.Firehose.Source)
  def current, do: Aerox.Sequencer.current(Repo, RepoSeq)
  def next_after(cursor), do: Aerox.Sequencer.next_after(Repo, RepoSeq, cursor)
  def earliest_after_time(time), do: Aerox.Sequencer.earliest_after_time(Repo, RepoSeq, time)
  def range(after_seq, limit), do: Aerox.Sequencer.range(Repo, RepoSeq, after_seq, limit)
  def backfill_window_ms, do: Aerox.Relay.Config.retention_ms()

  @doc "A stored row back into a frame; the Relay's seq replaces the upstream one, `time` is kept from upstream."
  def to_frame(%{seq: seq, event_type: type, event: bytes, sequenced_at: at}) do
    {:ok, body} = DagCBOR.decode(bytes)

    t =
      case type do
        "append" -> "#commit"
        "sync" -> "#sync"
        "identity" -> "#identity"
        "account" -> "#account"
      end

    body = body |> Map.put("seq", seq) |> Map.put_new("time", Syntax.format_datetime(at))
    {t, body}
  end
end
