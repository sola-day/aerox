defmodule AeroxWeb.AppView.LabelerController do
  @moduledoc "`app.bsky.labeler.getServices` on the AppView host (DESIGN §15.6; upstream `labeler/getServices.ts`)."
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  import AeroxWeb.AppView.Helpers
  alias Aerox.AppView.{Hydration, Views}

  def get_services(conn, _) do
    p = params!(conn, "app.bsky.labeler.getServices")
    dids = p["dids"] || []
    state = conn |> state() |> Hydration.hydrate_labelers(dids)

    views =
      for did <- dids,
          view =
            (if p["detailed"] do
               Views.labeler_detailed(did, state) &&
                 Map.put(
                   Views.labeler_detailed(did, state),
                   "$type",
                   "app.bsky.labeler.defs#labelerViewDetailed"
                 )
             else
               Views.labeler(did, state) &&
                 Map.put(Views.labeler(did, state), "$type", "app.bsky.labeler.defs#labelerView")
             end),
          not is_nil(view),
          do: view

    respond_labeled(conn, state, %{"views" => views})
  end
end
