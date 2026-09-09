defmodule Aerox.PDS do
  @moduledoc "Band 3: the PDS. Owns `Aerox.PDS.Repo` → `aerox_pds` (DESIGN §4)."
  use Boundary,
    top_level?: true,
    deps: [
      Aerox.ATProto,
      Aerox.Identity,
      Aerox.Auth,
      Aerox.Blob,
      Aerox.Crypto,
      Aerox.Mailer,
      Aerox.Sequencer
    ],
    exports: :all
end
