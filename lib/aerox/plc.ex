defmodule Aerox.PLC do
  @moduledoc "Band 3: the PLC directory. Owns `Aerox.PLC.Repo` → `aerox_core.plc`."
  use Boundary, top_level?: true, deps: [Aerox.ATProto, Aerox.Crypto], exports: :all
end
