defmodule Aerox.Crypto do
  @moduledoc "Band 2: the `Signer` behaviour and its implementations (DESIGN §14.2)."
  use Boundary, top_level?: true, deps: [Aerox.ATProto], exports: :all
end
