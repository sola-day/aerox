defmodule Aerox.PDS.Sequencer.Source do
  @moduledoc "The PDS sequencer as a firehose source (`AeroxWeb.Sockets.Firehose.Source`)."
  alias Aerox.PDS.Sequencer

  def topic, do: Sequencer.topic()
  def current, do: Sequencer.current()
  def next_after(cursor), do: Sequencer.next_after(cursor)
  def earliest_after_time(time), do: Sequencer.earliest_after_time(time)
  def range(after_seq, limit), do: Sequencer.range(after_seq, limit)
  def to_frame(row), do: Sequencer.Events.to_frame(row)
  # upstream PDS: three days
  def backfill_window_ms, do: 3 * 24 * 3600 * 1000
end
