defmodule AeroxWeb.Jetstream.ImportController do
  @moduledoc """
  `importTimestamps` and `getImportStatus` (upstream `xrpcapi/importts.go`):
  bearer-gated with the configured import token; with no token configured both
  answer 401, indistinguishable from a wrong token.
  """
  use AeroxWeb, :controller
  use AeroxWeb.Plugs.XRPCError
  import AeroxWeb.XRPC
  alias Aerox.Jetstream.{Config, Importer}
  alias AeroxWeb.XRPC.Error

  plug :bearer

  defp bearer(conn, _) do
    token = Config.import_token()

    presented =
      case get_req_header(conn, "authorization") do
        ["Bearer " <> t] -> t
        ["bearer " <> t] -> t
        _ -> nil
      end

    if is_binary(token) and token != "" and is_binary(presented) and
         Plug.Crypto.secure_compare(
           :crypto.hash(:sha256, presented),
           :crypto.hash(:sha256, token)
         ) do
      conn
    else
      conn
      |> AeroxWeb.Plugs.XRPCError.render(Error.auth_required("invalid or missing bearer token"))
      |> halt()
    end
  end

  def import_timestamps(conn, _) do
    case conn.body_params do
      %{"path" => path} when is_binary(path) ->
        case Importer.submit(path) do
          {:ok, id} ->
            respond(conn, %{"job" => id})

          {:error, :in_progress} ->
            {:error,
             %Error{
               status: 409,
               name: "ImportInProgress",
               message: "an import job is already running"
             }}

          {:error, :not_ready} ->
            {:error,
             %Error{
               status: 503,
               name: "ImportNotReady",
               message: "the steady-state writer is not running"
             }}

          {:error, {:invalid_path, msg}} ->
            {:error, %Error{status: 400, name: "InvalidPath", message: msg}}
        end

      _ ->
        {:error, Error.invalid_request("missing request body")}
    end
  end

  def get_import_status(conn, _) do
    id = conn.query_params["job"]

    case {Importer.status(id), id} do
      {nil, nil} ->
        {:error, %Error{status: 404, name: "JobNotFound", message: "no import job has run"}}

      {nil, _} ->
        {:error, %Error{status: 404, name: "JobNotFound", message: "job not found"}}

      {job, _} ->
        respond(conn, output(job))
    end
  end

  defp output(job) do
    c = job.counters

    %{
      "job" => job.id,
      "state" => job.state,
      "phase" => job.phase,
      "error" => job.error,
      "submittedAt" => job.submitted_at && ms(job.submitted_at),
      "finishedAt" => job.finished_at && ms(job.finished_at),
      "bucketed" => c["bucketed"] == true
    }
    |> Map.merge(
      Map.new(
        ~w(segmentsToApply segmentsApplied rowsTotal rowsValid rowsRejected segmentsExamined segmentsPatched rowsMutated rowsMatchedAllVersions rowsMatchedSpecific specificCidsUnmatched rowsCorruptOffset),
        &{&1, c[&1] || 0}
      )
    )
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp ms(dt),
    do:
      dt
      |> DateTime.truncate(:millisecond)
      |> Calendar.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
      |> String.replace(~r/\.(\d{3})\d*Z$/, ".\\1Z")
end
