defmodule Aerox.Interop do
  @moduledoc "Band 4: the account bundle and its adapters (DESIGN §13)."
  use Boundary,
    top_level?: true,
    deps: [Aerox.ATProto, Aerox.Blob, Aerox.Auth, Aerox.PDS],
    exports: :all
end
