defmodule AeroxWeb.AppView.Helpers do
  @moduledoc """
  Shared bits of the AppView controllers: the hydration state for the
  request (viewer from `AeroxWeb.AppView.Auth`, labelers from the
  `atproto-accept-labelers` header, DESIGN §15.6), the viewer requirement,
  and the mapping of the read-path modules' error reasons to XRPC errors.
  """
  import Plug.Conn
  alias Aerox.AppView.{Config, Hydration}
  alias AeroxWeb.XRPC.Error

  @doc "A hydration state for this request."
  def state(conn, opts \\ []) do
    Hydration.new([viewer: conn.assigns[:viewer], labelers: labelers(conn)] ++ opts)
  end

  @doc "The authenticated viewer DID, or `AuthMissing`."
  def viewer!(conn) do
    conn.assigns[:viewer] || raise Error.auth_required("Authentication Required", "AuthMissing")
  end

  @doc "Upstream `reqLabelers`: `atproto-accept-labelers: did:..;redact, did:..` → DIDs; defaults to the instance's set."
  def labelers(conn) do
    case get_req_header(conn, "atproto-accept-labelers") do
      [] ->
        Config.default_labelers()

      headers ->
        headers
        |> Enum.flat_map(&String.split(&1, ","))
        |> Enum.map(&(&1 |> String.trim() |> String.split(";") |> hd() |> String.trim()))
        |> Enum.filter(&String.starts_with?(&1, "did:"))
        |> Enum.uniq()
    end
  end

  @doc "Sends the view with the `atproto-content-labelers` header upstream's `resHeaders` adds."
  def respond_labeled(conn, state, body) do
    conn
    |> then(
      &case state.ctx.labelers do
        [] -> &1
        labelers -> put_resp_header(&1, "atproto-content-labelers", Enum.join(labelers, ","))
      end
    )
    |> AeroxWeb.XRPC.respond(body)
  end

  @doc "Raises the XRPC error for a read-path reason."
  def fail!(reason, actor \\ nil)
  def fail!(:not_found, nil), do: raise(Error.invalid_request("Profile not found"))
  def fail!(:not_found, actor), do: raise(Error.invalid_request("Actor not found: #{actor}"))

  def fail!(:takendown, _),
    do: raise(Error.invalid_request("Account has been suspended", "AccountTakedown"))

  def fail!(:deactivated, _),
    do: raise(Error.invalid_request("Account is deactivated", "AccountDeactivated"))

  def fail!(:self, _), do: raise(Error.invalid_request("Actor cannot mute themselves"))
  def fail!(:invalid_list, _), do: raise(Error.invalid_request("Invalid list uri"))
  def fail!(:invalid_post, _), do: raise(Error.invalid_request("Invalid post uri"))
  def fail!(other, _), do: raise(Error.invalid_request(to_string(other)))
end
