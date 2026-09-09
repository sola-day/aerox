defmodule Aerox.Interop do
  @moduledoc """
  Band 4: the account bundle and its adapters (DESIGN §13).

  `Aerox.Interop.Bundle` is the interchange format (§13.0, documented in
  `docs/BUNDLE.md`), `Aerox.Interop.Bundle.Postgres` moves accounts between
  `aerox_pds` and a bundle, `Aerox.Interop.Verify` is the §13.3 suite. The
  reference-PDS adapter lives in `lib_tool/` (`Aerox.Interop.ReferencePds`)
  and compiles only outside `prod`.

  Configuration is read from `config :aerox, Aerox.Interop` (all optional):

    * `:source_impl` / `:source_version` — what an exported manifest records
      as `source.impl` / `source.version` (defaults: `"aerox"` and the app
      version).
  """
  use Boundary,
    top_level?: true,
    deps: [Aerox.ATProto, Aerox.Blob, Aerox.Auth, Aerox.Crypto, Aerox.PDS],
    exports: :all

  @doc "The configured `Aerox.Interop` keyword list."
  @spec config() :: keyword
  def config, do: Application.get_env(:aerox, __MODULE__, [])
end
