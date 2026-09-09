defmodule AeroxWeb.OAuthController do
  @moduledoc """
  The authorization server's HTTP surface (DESIGN §11.2, upstream
  `router/create-oauth-middleware.ts` + the authorize page): metadata, JWKS,
  PAR, token, revoke as JSON endpoints with OAuth error bodies, and the
  consent pages on the `:browser` pipeline (device cookie, CSRF form).
  """
  use AeroxWeb, :controller
  import Plug.Conn
  alias Aerox.Auth.DPoP
  alias Aerox.PDS.OAuth

  plug :no_store

  defp no_store(conn, _),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("pragma", "no-cache")

  # ------------------------------------------------------------ metadata

  def server_metadata(conn, _), do: json(conn, OAuth.server_metadata())
  def protected_resource(conn, _), do: json(conn, OAuth.protected_resource_metadata())
  def jwks(conn, _), do: json(conn, OAuth.jwks())

  # ---------------------------------------------------------- endpoints

  def par(conn, _), do: oauth_json(conn, 201, fn dpop -> OAuth.par(conn.body_params, dpop) end)

  def token(conn, _),
    do: oauth_json(conn, 200, fn dpop -> OAuth.token(conn.body_params, dpop) end)

  def revoke(conn, _) do
    oauth_json(conn, 200, fn dpop ->
      case OAuth.revoke(conn.body_params, dpop) do
        :ok -> {:ok, %{}}
        {:error, _} -> {:ok, %{}}
      end
    end)
  end

  defp oauth_json(conn, status, fun) do
    conn = AeroxWeb.Plugs.Auth.with_dpop_nonce(conn)
    url = Aerox.PDS.Config.public_url() <> conn.request_path

    result =
      with {:ok, dpop} <-
             DPoP.verify(conn |> get_req_header("dpop") |> List.first(), conn.method, url) do
        fun.(dpop)
      end

    case result do
      {:ok, body} ->
        conn |> put_status(status) |> json(body)

      {:error, :use_dpop_nonce} ->
        conn
        |> put_resp_header("www-authenticate", DPoP.www_authenticate(:use_dpop_nonce))
        |> put_status(400)
        |> json(%{
          "error" => "use_dpop_nonce",
          "error_description" => "Authorization server requires nonce in DPoP proof"
        })

      {:error, {error, description}} ->
        conn
        |> put_status(error_status(error))
        |> json(%{"error" => to_string(error), "error_description" => description})

      {:error, {error, description, _params}} ->
        conn
        |> put_status(error_status(error))
        |> json(%{"error" => to_string(error), "error_description" => description})
    end
  end

  defp error_status(:invalid_client), do: 401
  defp error_status(:invalid_token), do: 401
  defp error_status(:invalid_dpop_proof), do: 400
  defp error_status(_), do: 400

  # ------------------------------------------------------ authorize page

  def authorize(conn, params) do
    {conn, device_id} = device(conn)

    case OAuth.authorize(params, device_id) do
      {:page, page} ->
        conn
        |> put_layout(false)
        |> render(:authorize, page: page, error: nil, csrf: Plug.CSRFProtection.get_csrf_token())

      {:redirect, parameters, extra} ->
        send_redirect(conn, OAuth.redirect(parameters, extra))

      {:error, {_error, description, parameters}} ->
        send_redirect(
          conn,
          OAuth.redirect(parameters, %{
            "error" => "access_denied",
            "error_description" => description
          })
        )

      {:error, {error, description}} ->
        conn
        |> put_status(400)
        |> put_layout(false)
        |> render(:error, error: to_string(error), description: description)
    end
  end

  def sign_in(conn, %{"request_uri" => request_uri} = params) do
    {conn, device_id} = device(conn)

    meta = %{
      user_agent: conn |> get_req_header("user-agent") |> List.first(),
      ip: AeroxWeb.Plugs.ClientIP.client_ip(conn) |> :inet.ntoa() |> to_string()
    }

    case OAuth.sign_in(
           request_uri,
           params["identifier"] || "",
           params["password"] || "",
           device_id,
           meta
         ) do
      {:ok, _did} ->
        redirect(conn,
          to: ~p"/oauth/authorize?#{[client_id: params["client_id"], request_uri: request_uri]}"
        )

      {:error, {_, msg}} ->
        case OAuth.authorize(
               %{"client_id" => params["client_id"], "request_uri" => request_uri},
               device_id
             ) do
          {:page, page} ->
            conn
            |> put_status(400)
            |> put_layout(false)
            |> render(:authorize,
              page: page,
              error: msg,
              csrf: Plug.CSRFProtection.get_csrf_token()
            )

          _ ->
            conn
            |> put_status(400)
            |> put_layout(false)
            |> render(:error, error: "invalid_request", description: msg)
        end
    end
  end

  def accept(conn, %{"request_uri" => request_uri, "did" => did} = params) do
    {conn, device_id} = device(conn)

    case OAuth.consent(request_uri, did, device_id, params["scope"]) do
      {:ok, parameters, extra} ->
        send_redirect(conn, OAuth.redirect(parameters, extra))

      {:redirect_error, parameters, extra} ->
        send_redirect(conn, OAuth.redirect(parameters, extra))

      {:error, {error, description}} ->
        conn
        |> put_status(400)
        |> put_layout(false)
        |> render(:error, error: to_string(error), description: description)
    end
  end

  def reject(conn, %{"request_uri" => request_uri}) do
    case OAuth.reject(request_uri) do
      {:ok, parameters, extra} ->
        send_redirect(conn, OAuth.redirect(parameters, extra))

      {:error, {error, description}} ->
        conn
        |> put_status(400)
        |> put_layout(false)
        |> render(:error, error: to_string(error), description: description)
    end
  end

  # The client redirect in the requested response_mode (RFC 6749 / OAuth 2.0
  # multiple response types / form_post).
  defp send_redirect(conn, {mode, redirect_uri, query}) do
    encoded = URI.encode_query(query)

    case mode do
      "fragment" ->
        redirect(conn, external: redirect_uri <> "#" <> encoded)

      "form_post" ->
        conn |> put_layout(false) |> render(:form_post, redirect_uri: redirect_uri, params: query)

      _ ->
        sep = if String.contains?(redirect_uri, "?"), do: "&", else: "?"
        redirect(conn, external: redirect_uri <> sep <> encoded)
    end
  end

  # ------------------------------------------------------- device cookie

  @cookie "aerox-device"
  @max_age 365 * 24 * 3600

  defp device(conn) do
    conn = fetch_cookies(conn, signed: [@cookie])

    case conn.cookies[@cookie] do
      "dev-" <> _ = id ->
        {conn, id}

      _ ->
        id = "dev-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

        OAuth.ensure_device(id, %{
          user_agent: conn |> get_req_header("user-agent") |> List.first()
        })

        {put_resp_cookie(conn, @cookie, id,
           sign: true,
           http_only: true,
           same_site: "Lax",
           secure: conn.scheme == :https,
           max_age: @max_age
         ), id}
    end
  end
end
