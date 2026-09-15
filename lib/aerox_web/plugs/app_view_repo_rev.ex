defmodule AeroxWeb.AppView.RepoRev do
  @moduledoc """
  Sync spec, "Repository Revisions": a service tells an authenticated caller
  how far it has synchronised *the caller's own* repository with the
  `Atproto-Repo-Rev` response header — the rev of the last commit indexed for
  that account — so a client that has just written can tell whether a read
  already reflects the write. Upstream sets it from `getRepoRevSafe(viewer)` on
  every AppView response, errors included; so does this, from `actor_sync`.
  Unauthenticated requests get no header.

  Runs after `AeroxWeb.AppView.Auth`, which assigns `:viewer`.
  """
  @behaviour Plug
  import Plug.Conn
  alias Aerox.AppView.Schema.ActorSync

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{assigns: %{viewer: viewer}} = conn, _) when is_binary(viewer) do
    register_before_send(conn, fn conn ->
      case rev(viewer) do
        nil -> conn
        rev -> put_resp_header(conn, "atproto-repo-rev", rev)
      end
    end)
  end

  def call(conn, _), do: conn

  defp rev(did) do
    case Aerox.AppView.Repo.get(ActorSync, did) do
      %ActorSync{repo_rev: rev} -> rev
      nil -> nil
    end
  rescue
    # never fail a response over its advisory header
    _ -> nil
  end
end
