defmodule AeroxWeb.Labeler.ModerationController do
  @moduledoc """
  Report intake and the moderation admin API on the Labeler host (DESIGN
  §17.2, §17.3): `com.atproto.moderation.createReport` (a service JWT for
  the reporter, proxied by their PDS) and `aerox.moderation.emitEvent` /
  `queryEvents` / `queryReports` (HTTP Basic admin).
  """
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  import AeroxWeb.Labeler.Auth, only: [caller!: 1, admin!: 1]
  alias Aerox.Labeler.{Actions, Reports}
  alias AeroxWeb.XRPC.Error

  def create_report(conn, _) do
    reporter = caller!(conn)
    input = input!(conn, "com.atproto.moderation.createReport")

    case Reports.create(%{
           subject: input["subject"],
           reason_type: input["reasonType"],
           reason: input["reason"],
           reported_by: reporter
         }) do
      {:ok, report} -> respond(conn, Reports.view(report))
      {:error, msg} when is_binary(msg) -> {:error, Error.invalid_request(msg)}
      {:error, _} -> {:error, Error.invalid_request("Could not store report")}
    end
  end

  def emit_event(conn, _) do
    admin!(conn)
    input = input!(conn, "aerox.moderation.emitEvent")

    case Actions.emit(%{
           action: input["action"],
           subject: input["subject"],
           created_by: input["createdBy"] || "admin",
           comment: input["comment"],
           meta: input["meta"] || %{}
         }) do
      {:ok, event} ->
        respond(conn, Actions.view(event))

      {:error, msg} when is_binary(msg) ->
        {:error, Error.invalid_request(msg)}

      {:error, reason} ->
        {:error, Error.upstream_failure("Could not apply action: #{inspect(reason)}")}
    end
  end

  def query_events(conn, _) do
    admin!(conn)
    p = params!(conn, "aerox.moderation.queryEvents")
    {rows, cursor} = Actions.list(subject: p["subject"], limit: p["limit"], cursor: p["cursor"])
    body = %{"events" => Enum.map(rows, &Actions.view/1)}
    respond(conn, if(cursor, do: Map.put(body, "cursor", cursor), else: body))
  end

  def query_reports(conn, _) do
    admin!(conn)
    p = params!(conn, "aerox.moderation.queryReports")
    {rows, cursor} = Reports.list(subject: p["subject"], limit: p["limit"], cursor: p["cursor"])
    body = %{"reports" => Enum.map(rows, &Reports.view/1)}
    respond(conn, if(cursor, do: Map.put(body, "cursor", cursor), else: body))
  end
end
