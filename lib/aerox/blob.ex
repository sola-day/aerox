defmodule Aerox.Blob do
  @moduledoc "Band 2: the `Store` behaviour and its adapters (DESIGN §4.4)."
  use Boundary, top_level?: true, deps: [Aerox.ATProto], exports: :all
end
