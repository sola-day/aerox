defmodule Aerox.AppView do
  @moduledoc """
  Band 3: the AppView. Owns `Aerox.AppView.Repo` → `aerox_core.appview`.
  `Aerox.PDS` is deliberately absent from `deps` (STRUCTURE §6 rule 2).
  """
  use Boundary,
    top_level?: true,
    deps: [Aerox.ATProto, Aerox.Identity, Aerox.Auth, Aerox.Blob, Aerox.ImageServer],
    exports: :all
end
