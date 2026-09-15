defmodule AeroxWeb.OAuthHTML do
  @moduledoc "The consent pages (DESIGN §2: the one or two HTML pages the :browser pipeline exists for)."
  use AeroxWeb, :html

  embed_templates "oauth_html/*"

  def scope_lines(nil), do: []

  def scope_lines(scope) do
    scope
    |> String.split(" ", trim: true)
    |> Enum.map(fn
      "atproto" -> "Sign in with your atproto account"
      "transition:generic" -> "Full access to your account data (transition:generic)"
      "transition:email" -> "Read your email address"
      "transition:chat.bsky" -> "Access your direct messages"
      "include:" <> _ = include -> permission_set_line(include)
      other -> other
    end)
  end

  # a permission set speaks for itself: its title and detail (Permission spec)
  defp permission_set_line(include) do
    with {:include, %{nsid: nsid}} <- Aerox.Auth.Scopes.parse(include),
         %{} = set <- Aerox.PDS.Lexicons.permission_set(nsid) do
      [set["title"] || nsid, set["detail"]] |> Enum.reject(&is_nil/1) |> Enum.join(" — ")
    else
      _ -> include
    end
  end

  def client_name(client), do: client.metadata["client_name"] || client.id
end
