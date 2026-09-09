defmodule AeroxWeb.Labeler.Auth do
  @moduledoc """
  The Labeler's inbound auth (DESIGN §20.2): a `Bearer` service JWT from the
  caller's PDS (`iss` = the caller's DID, `aud` = the labeler's account DID
  or `did:web:<labeler host>`, `lxm` = the NSID), verified with the shared
  `Aerox.Auth.ServiceJWT` verifier through the Labeler's identity cache,
  sets `assigns.caller`; HTTP Basic `admin:<admin password>` sets
  `assigns.labeler_admin?` for the `aerox.moderation.*` API. Requests
  without a token are anonymous; a bad token is refused.
  """
  import Plug.Conn
  alias Aerox.Labeler.Config
  alias AeroxWeb.XRPC.Error

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = conn |> assign(:caller, nil) |> assign(:labeler_admin?, false)

    case get_req_header(conn, "authorization") do
      [] ->
        conn

      ["Bearer " <> token] ->
        bearer(conn, String.trim(token))

      ["Basic " <> creds] ->
        basic(conn, creds)

      _ ->
        AeroxWeb.Plugs.XRPCError.render(
          conn,
          Error.invalid_request("Unexpected authorization type", "InvalidToken")
        )
    end
  end

  defp bearer(conn, token) do
    nsid = AeroxWeb.XRPC.nsid(conn)

    resolver = fn iss, force ->
      Aerox.Identity.resolve_signing_key(
        Aerox.Labeler.Identity,
        iss |> String.split("#") |> hd(),
        force: force
      )
    end

    # two audiences are accepted, so the verifier's own check is skipped and done here
    with {:ok, claims} <- Aerox.Auth.ServiceJWT.verify(token, nil, nsid, resolver),
         :ok <- check_aud(claims.aud) do
      assign(conn, :caller, claims.iss |> String.split("#") |> hd())
    else
      {:error, {name, msg}} ->
        AeroxWeb.Plugs.XRPCError.render(conn, Error.auth_required(msg, name))
    end
  end

  defp check_aud(aud) do
    if aud in Config.service_dids(),
      do: :ok,
      else: {:error, {"BadJwtAudience", "jwt audience does not match service did"}}
  end

  defp basic(conn, creds) do
    with {:ok, decoded} <- Base.decode64(creds),
         ["admin", password] <- String.split(decoded, ":", parts: 2),
         expected when is_binary(expected) <- Config.admin_password(),
         true <- Plug.Crypto.secure_compare(password, expected) do
      assign(conn, :labeler_admin?, true)
    else
      _ -> AeroxWeb.Plugs.XRPCError.render(conn, Error.auth_required())
    end
  end

  @doc "The authenticated caller DID, or `AuthMissing`."
  def caller!(conn),
    do:
      conn.assigns[:caller] ||
        raise(Error.auth_required("Authentication Required", "AuthMissing"))

  @doc "Raises unless the request carries the admin credentials."
  def admin!(conn) do
    if conn.assigns[:labeler_admin?], do: :ok, else: raise(Error.auth_required())
  end
end
