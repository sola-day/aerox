defmodule Aerox.ATProto do
  @moduledoc """
  Band 1: the kernel (DESIGN §3). Pure functions only — no I/O, no Ecto, no
  Phoenix, no processes. `deps: []` is the mechanical form of that rule
  (STRUCTURE §6): the compiler refuses a reference to anything outside this
  tree except the standard library and the crypto NIF.
  """
  use Boundary, top_level?: true, deps: [], exports: :all
end
