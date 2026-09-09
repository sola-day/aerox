defmodule Aerox.Relay do
  @moduledoc "Band 3: the Relay. Owns `Aerox.Relay.Repo` → `aerox_core.relay` (DESIGN §19)."
  use Boundary, top_level?: true, deps: [Aerox.ATProto, Aerox.Identity], exports: :all
end
