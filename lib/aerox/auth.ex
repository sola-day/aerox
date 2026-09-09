defmodule Aerox.Auth do
  @moduledoc """
  Band 2: scope grammar, the single DPoP verifier, service JWTs and
  upstream-compatible scrypt (DESIGN §11.2, §12.4, §20.2, §13.4).
  """
  use Boundary, top_level?: true, deps: [Aerox.ATProto, Aerox.Identity], exports: :all
end
