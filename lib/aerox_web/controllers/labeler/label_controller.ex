defmodule AeroxWeb.Labeler.LabelController do
  @moduledoc "`com.atproto.label.queryLabels` on the Labeler host (DESIGN §17.1; upstream ozone `queryLabels.ts`)."
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  alias Aerox.Labeler.Labels
  alias AeroxWeb.XRPC.Error

  def query_labels(conn, _) do
    p = params!(conn, "com.atproto.label.queryLabels")

    case Labels.query(%{
           uri_patterns: p["uriPatterns"],
           sources: p["sources"],
           limit: p["limit"],
           cursor: p["cursor"]
         }) do
      {:ok, {rows, cursor}} ->
        body = %{"labels" => Enum.map(rows, &Labels.to_wire/1)}
        respond(conn, if(cursor, do: Map.put(body, "cursor", cursor), else: body))

      {:error, msg} ->
        {:error, Error.invalid_request(msg)}
    end
  end
end
