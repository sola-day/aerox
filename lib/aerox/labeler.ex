defmodule Aerox.Labeler do
  @moduledoc "Band 3: the Labeler / moderation backend (DESIGN §17)."
  use Boundary,
    top_level?: true,
    deps: [Aerox.ATProto, Aerox.Identity, Aerox.Auth, Aerox.Crypto, Aerox.Sequencer],
    exports: :all
end
