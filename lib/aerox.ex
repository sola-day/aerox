defmodule Aerox do
  @moduledoc """
  Top-level boundary: the supervision tree, service list and shared
  application-level modules (`Aerox.Services`, `Aerox.Mailer`);
  `Aerox.Application` is its own boundary because it starts `AeroxWeb.Endpoint`. Bands 1–4 of STRUCTURE §3 are their own boundaries.
  """
  use Boundary,
    deps: [
      Aerox.ATProto,
      Aerox.Identity,
      Aerox.Crypto,
      Aerox.Blob,
      Aerox.Auth,
      Aerox.PDS,
      Aerox.PLC,
      Aerox.Relay,
      Aerox.AppView,
      Aerox.Labeler,
      Aerox.ImageServer,
      Aerox.Interop
    ],
    exports: [Services, Mailer]
end
