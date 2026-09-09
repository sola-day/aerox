defmodule AeroxWeb.XRPC do
  @moduledoc """
  Helpers for XRPC controllers (DESIGN §2): parameter and input validation
  through the vendored lexicon registry (DESIGN §6.6: validation errors
  carry a JSON-pointer path and become `InvalidRequest`), JSON responses of
  data-model values, and the lexicon NSID of the current route.
  """
  import Plug.Conn
  alias Aerox.ATProto.{Data, Lexicon}
  alias AeroxWeb.XRPC.Error

  @doc "Query params validated against the lexicon's `parameters` (types coerced from strings, defaults filled)."
  @spec params!(Plug.Conn.t(), String.t()) :: map
  def params!(conn, nsid) do
    raw = coerce_params(conn.query_params, nsid)

    case Lexicon.validate_params(Lexicon.default_registry(), nsid, raw) do
      {:ok, params} -> params
      {:error, {msg, _path}} -> raise Error.invalid_request("Error: Params #{msg}")
    end
  end

  # Query strings are all strings; the lexicon says which are integers,
  # booleans or arrays.
  defp coerce_params(query, nsid) do
    case Aerox.ATProto.Lexicon.Registry.get_def(Lexicon.default_registry(), nsid) do
      {:ok, %{"parameters" => %{"properties" => props}}} ->
        Map.new(query, fn {k, v} ->
          case Map.get(props, k) do
            %{"type" => "integer"} ->
              {k, to_int(v)}

            %{"type" => "boolean"} ->
              {k, to_bool(v)}

            %{"type" => "array", "items" => %{"type" => "integer"}} ->
              {k, v |> List.wrap() |> Enum.map(&to_int/1)}

            %{"type" => "array"} ->
              {k, List.wrap(v)}

            _ ->
              {k, v}
          end
        end)

      _ ->
        query
    end
  end

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, ""} -> i
      _ -> v
    end
  end

  defp to_int(v), do: v
  defp to_bool("true"), do: true
  defp to_bool("false"), do: false
  defp to_bool(v), do: v

  @doc "JSON input body validated against the lexicon's `input.schema`, converted to the data model."
  @spec input!(Plug.Conn.t(), String.t()) :: map
  def input!(conn, nsid) do
    body = conn.body_params

    case Lexicon.validate_input(Lexicon.default_registry(), nsid, body) do
      {:ok, validated} -> validated
      {:error, {msg, _path}} -> raise Error.invalid_request("Error: Input #{msg}")
    end
  end

  @doc "Sends a data-model value as JSON (CIDs and bytes in their JSON forms)."
  @spec respond(Plug.Conn.t(), term, pos_integer) :: Plug.Conn.t()
  def respond(conn, value, status \\ 200) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(Data.to_json(value)))
  end

  @doc "The NSID of the current `/xrpc/<nsid>` route."
  @spec nsid(Plug.Conn.t()) :: String.t()
  def nsid(%Plug.Conn{path_info: ["xrpc", nsid | _]}), do: nsid
  def nsid(_), do: ""

  @doc "Raises `Error` unless the assigned auth is one of the accepted kinds and scopes."
  @spec require_auth!(Plug.Conn.t(), keyword) :: map
  def require_auth!(conn, opts \\ []) do
    kinds = Keyword.get(opts, :kinds, [:access])
    scopes = Keyword.get(opts, :scopes, Aerox.PDS.Sessions.access_standard())

    case conn.assigns[:auth] do
      %{type: type} = auth when type in [:access] ->
        if type in kinds and auth.scope in scopes,
          do: auth,
          else: raise(Error.invalid_request("Bad token scope", "InvalidToken"))

      %{type: type} = auth ->
        if type in kinds,
          do: auth,
          else: raise(Error.invalid_request("Unexpected authorization type", "InvalidToken"))

      _ ->
        raise Error.auth_required("Authentication Required", "AuthMissing")
    end
  end

  @doc "The authenticated DID, or raises."
  def did!(conn, opts \\ []), do: require_auth!(conn, opts).did
end
