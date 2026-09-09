defmodule AeroxWeb.PLC.PLCController do
  @moduledoc """
  The did:plc directory's plain-REST surface (DESIGN §2, §6.4), matching
  `did-method-plc/packages/server/src/routes.ts` route for route:
  `/_health`, `/export`, `/:did`, `/:did/data`, `/:did/log`,
  `/:did/log/audit`, `/:did/log/last`, `POST /:did`, and the admin
  `removeInvalidOps`.
  """
  use AeroxWeb, :controller
  alias Aerox.PLC.Directory

  def health(conn, _params) do
    case Aerox.PLC.Repo.query("SELECT 1") do
      {:ok, _} ->
        json(conn, %{"version" => Application.spec(:aerox, :vsn) |> to_string()})

      _ ->
        conn
        |> put_status(503)
        |> json(%{
          "version" => Application.spec(:aerox, :vsn) |> to_string(),
          "error" => "Service Unavailable"
        })
    end
  end

  def export(conn, params) do
    with {:ok, count} <- parse_count(params["count"]),
         {:ok, after_} <- parse_after(params["after"]) do
      lines = Directory.export(count, after_) |> Enum.map_join("\n", &Jason.encode!/1)

      conn
      |> put_resp_content_type("application/jsonlines", nil)
      |> send_resp(200, lines)
    else
      {:error, msg} -> error(conn, 400, msg)
    end
  end

  def document(conn, %{"did" => did}) do
    case Directory.did_document(did) do
      {:ok, doc} ->
        conn
        |> put_resp_content_type("application/did+ld+json", nil)
        |> send_resp(200, Jason.encode!(doc))

      {:error, :not_found} ->
        error(conn, 404, "DID not registered: #{did}")

      {:error, :tombstoned} ->
        error(conn, 404, "DID not available: #{did}")
    end
  end

  def data(conn, %{"did" => did}) do
    case Directory.document_data(did) do
      {:ok, data} -> json(conn, data_json(data))
      {:error, :not_found} -> error(conn, 404, "DID not registered: #{did}")
      {:error, :tombstoned} -> error(conn, 404, "DID not available: #{did}")
    end
  end

  def log(conn, %{"did" => did}) do
    case Directory.indexed_ops(did, false) do
      [] -> error(conn, 404, "DID not registered: #{did}")
      ops -> json(conn, Enum.map(ops, & &1.operation))
    end
  end

  def audit(conn, %{"did" => did}) do
    case Directory.audit_log(did) do
      [] -> error(conn, 404, "DID not registered: #{did}")
      log -> json(conn, log)
    end
  end

  def last(conn, %{"did" => did}) do
    case Directory.last_op(did) do
      nil -> error(conn, 404, "DID not registered: #{did}")
      op -> json(conn, op)
    end
  end

  def submit(conn, %{"did" => did} = params) do
    op = Map.drop(params, ["did"])
    op = if conn.body_params == %{}, do: op, else: conn.body_params

    case Directory.submit(did, op, DateTime.utc_now()) do
      {:ok, _} -> send_resp(conn, 200, "OK")
      {:error, {:bad_request, msg}} -> error(conn, 400, msg)
      {:error, {:conflict, msg}} -> error(conn, 409, msg)
      {:error, {:not_found, msg}} -> error(conn, 404, msg)
    end
  end

  def remove_invalid_ops(conn, params) do
    secret = Application.get_env(:aerox, :plc_admin_secret)

    cond do
      is_nil(secret) ->
        error(conn, 401, "admin secret has not been configured")

      not Plug.Crypto.secure_compare(to_string(params["adminSecret"]), secret) ->
        error(conn, 401, "invalid admin secret")

      not (is_binary(params["did"]) and is_binary(params["cid"])) ->
        error(conn, 400, "did and cid are required")

      true ->
        case Directory.remove_invalid_ops(params["did"], params["cid"]) do
          {:ok, removed} -> json(conn, removed)
          {:error, {_, msg}} -> error(conn, 400, msg)
        end
    end
  end

  defp parse_count(nil), do: {:ok, 1000}

  defp parse_count(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 1 -> {:ok, min(n, 1000)}
      _ -> {:error, "Invalid count parameter"}
    end
  end

  defp parse_after(nil), do: {:ok, nil}

  defp parse_after(str) do
    cond do
      Regex.match?(~r/^\d+$/, str) ->
        {:ok, String.to_integer(str)}

      true ->
        case DateTime.from_iso8601(str) do
          {:ok, dt, _} -> {:ok, dt}
          _ -> {:error, "Invalid after parameter"}
        end
    end
  end

  defp data_json(data) do
    %{
      "did" => data.did,
      "rotationKeys" => data.rotation_keys,
      "verificationMethods" => data.verification_methods,
      "alsoKnownAs" => data.also_known_as,
      "services" =>
        Map.new(data.services, fn {id, s} ->
          {id, %{"type" => s.type, "endpoint" => s.endpoint}}
        end)
    }
  end

  defp error(conn, status, message),
    do: conn |> put_status(status) |> json(%{"message" => message})
end
