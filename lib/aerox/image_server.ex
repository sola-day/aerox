defmodule Aerox.ImageServer do
  @moduledoc "Band 3: the image CDN, inside the AppView process but its own tree (DESIGN §16)."
  use Boundary, top_level?: true, deps: [Aerox.ATProto, Aerox.Identity], exports: :all
end
