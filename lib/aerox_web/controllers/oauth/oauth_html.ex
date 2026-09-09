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
      other -> other
    end)
  end

  def client_name(client), do: client.metadata["client_name"] || client.id
end
