defmodule Aerox.Identity do
  @moduledoc """
  Band 2: the impure half of DESIGN §3.0 — DID and handle *resolution* with a
  cache (DESIGN §20.1). Parsing stays in the kernel.
  """
  use Boundary, top_level?: true, deps: [Aerox.ATProto], exports: :all
end
