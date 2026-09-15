defmodule Aerox.Jetstream.Config do
  @moduledoc """
  Jetstream settings from `config :aerox, Aerox.Jetstream`; defaults are
  jetstream's (docs/README.md): 4096-event blocks flushed at least every 30 s,
  ~256 MB segments, a 36 h cursor lookback, compaction every 4 h with a 5 min
  cache grace.
  """
  def all, do: Application.get_env(:aerox, Aerox.Jetstream, [])
  def get(key, default \\ nil), do: Keyword.get(all(), key, default)

  def hostname, do: get(:hostname) || "jetstream.localhost"
  def public_url, do: get(:public_url) || "https://" <> hostname()
  def relay_url, do: get(:relay_url) || "wss://relay.localhost"
  def data_dir, do: get(:data_dir) || "tmp/jetstream"
  def segments_dir, do: Path.join(data_dir(), "segments")
  def import_dir, do: get(:import_dir) || Path.join(data_dir(), "imports")

  @doc "Whether the ingest, flush and compaction processes start (tests start them explicitly)."
  def workers?, do: get(:workers, true)

  def max_events_per_block, do: get(:max_events_per_block, 4096)
  def block_max_age_ms, do: get(:block_max_age_ms, 30_000)
  def segment_bytes, do: get(:segment_bytes, 256 * 1024 * 1024)
  def lookback_ms, do: get(:lookback_ms, 36 * 3600 * 1000)
  def compaction_interval_ms, do: get(:compaction_interval_ms, 4 * 3600 * 1000)
  def compaction_tombstone_cap, do: get(:compaction_tombstone_cap, 32_000_000)
  def compaction_cache_grace_ms, do: get(:compaction_cache_grace_ms, 5 * 60 * 1000)
  def import_token, do: get(:import_token)

  def plan_max_dids, do: get(:plan_max_dids, 10_000)
  def plan_max_collections, do: get(:plan_max_collections, 100)
  def plan_max_entries, do: get(:plan_max_entries, 100_000)
  def plan_whole_segment_threshold, do: get(:plan_whole_segment_threshold, 0.75)

  def read_batch, do: get(:read_batch, 1024)
  def slow_window_ms, do: get(:slow_window_ms, 60_000)
  def slow_min_rate, do: get(:slow_min_rate, 5.0)
  def slow_lag_threshold, do: get(:slow_lag_threshold, 100_000)
end
