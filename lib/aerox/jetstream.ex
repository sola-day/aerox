defmodule Aerox.Jetstream do
  @moduledoc """
  Band 3: Jetstream (docs/PARITY.md) — a JSON firehose and full-network
  archive over the Relay, speaking jetstream's wire contracts (`/subscribe`,
  `network.bsky.jetstream.*`) and its segment format.

  Consumes the Relay's `subscribeRepos` like any other client (no shared
  tables, DESIGN §4.6), appends every op as a row with a sequence number,
  groups rows into zstd blocks and blocks into `.jss` segment files, and
  serves live tails, cursor replay, and archive downloads from them.
  """
  use Boundary, top_level?: true, deps: [Aerox.ATProto, Aerox.Identity], exports: :all
end
