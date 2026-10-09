defmodule AeroxWeb.Labeler.ModerationController do
  @moduledoc """
  Report intake and the moderation admin API on the Labeler host (DESIGN
  §17.2, §17.3): `com.atproto.moderation.createReport` (a service JWT for
  the reporter, proxied by their PDS) and `aerox.moderation.emitEvent` /
  `queryEvents` / `queryReports` / `queryPosts` (HTTP Basic admin).
  """
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  import AeroxWeb.Labeler.Auth, only: [caller!: 1, admin!: 1]
  alias Aerox.AppView.{Feeds, Hydration, Views}
  alias Aerox.Labeler.{Actions, Reports}
  alias AeroxWeb.AppView.FeedController
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

  # top-level posts with their takedown status, read from the AppView in this
  # node — the admin's list to take posts down from and restore them in
  def query_posts(conn, _) do
    admin!(conn)

    if not Aerox.AppView.Moderation.enabled?(),
      do: raise(Error.not_implemented("queryPosts needs the AppView in this node"))

    p = params!(conn, "aerox.moderation.queryPosts")
    %{q: q, author: author} = Feeds.parse_search_query(p["q"] || "", p["author"])

    filters = %{
      author:
        author &&
          (Feeds.resolve_actor(author) || raise(Error.invalid_request("Profile not found"))),
      tags: FeedController.search_tags(p),
      since: FeedController.search_bound(p["since"]),
      until: FeedController.search_bound(p["until"]),
      replies: false,
      takedowns: %{nil => :include, true => :only, false => :exclude}[p["takenDown"]]
    }

    {uris, cursor, total} =
      case Feeds.search_posts(q, filters, p["limit"], p["cursor"]) do
        {:ok, r} -> {r.uris, r.cursor, r.hits_total}
        {:error, :malformed_cursor} -> raise Error.invalid_request("Malformed cursor")
      end

    state =
      Hydration.new(include_takedowns: true)
      |> Hydration.hydrate_posts(uris)
      |> Feeds.finish_posts()

    taken = Feeds.taken_down(uris)

    posts =
      for uri <- uris,
          post = Views.post(uri, state),
          do: %{"post" => post, "takenDown" => MapSet.member?(taken, uri)}

    body = %{"posts" => posts, "hitsTotal" => total}
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
