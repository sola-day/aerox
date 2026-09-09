defmodule Aerox.Labeler.Sequencer do
  @moduledoc """
  The Labeler's sequencer over `labeler.label_seq` (DESIGN §17.1: the same
  single-writer/event-table pattern as the firehose, §5), fanned out on
  topic `"labeler:labels"`. One event per `#labels` frame; the stored
  `event` is the DAG-CBOR body without `seq`, `to_frame/1` puts it in.
  """
  alias Aerox.ATProto.DagCBOR
  alias Aerox.Labeler.Repo
  alias Aerox.Labeler.Schema.LabelSeq

  @topic "labeler:labels"
  def topic, do: @topic

  def child_spec(opts),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}

  def start_link(opts \\ []) do
    Aerox.Sequencer.start_link(
      name: Keyword.get(opts, :name, __MODULE__),
      repo: Repo,
      schema: LabelSeq,
      topic: @topic,
      unboxed: Application.get_env(:aerox, __MODULE__, [])[:unboxed] || false
    )
  end

  @doc "Sequences one `#labels` event carrying the given wire-form labels; returns its seq."
  @spec sequence_labels(String.t(), [map], GenServer.server()) ::
          {:ok, pos_integer} | {:error, term}
  def sequence_labels(src, labels, server \\ __MODULE__) do
    row = %{did: src, event_type: "labels", event: DagCBOR.encode(%{"labels" => labels})}

    case Aerox.Sequencer.sequence(server, [row]) do
      {:ok, [seq]} -> {:ok, seq}
      {:error, _} = e -> e
    end
  end

  def current, do: Aerox.Sequencer.current(Repo, LabelSeq)
  def next_after(cursor), do: Aerox.Sequencer.next_after(Repo, LabelSeq, cursor)
  def earliest_after_time(time), do: Aerox.Sequencer.earliest_after_time(Repo, LabelSeq, time)
  def range(after_seq, limit), do: Aerox.Sequencer.range(Repo, LabelSeq, after_seq, limit)

  @doc "A stored row back into a `{\"#labels\", body}` frame."
  def to_frame(%{seq: seq, event_type: "labels", event: bytes}) do
    {:ok, body} = DagCBOR.decode(bytes)
    {"#labels", Map.put(body, "seq", seq)}
  end
end

defmodule Aerox.Labeler.Labels.Source do
  @moduledoc "The Labeler's sequencer as a `com.atproto.label.subscribeLabels` source (the `AeroxWeb.Sockets.Firehose.Source` callbacks)."
  alias Aerox.Labeler.Sequencer

  def topic, do: Sequencer.topic()
  def current, do: Sequencer.current()
  def next_after(cursor), do: Sequencer.next_after(cursor)
  def earliest_after_time(time), do: Sequencer.earliest_after_time(time)
  def range(after_seq, limit), do: Sequencer.range(after_seq, limit)
  def to_frame(row), do: Sequencer.to_frame(row)
  def backfill_window_ms, do: Aerox.Labeler.Config.backfill_window_ms()
end
