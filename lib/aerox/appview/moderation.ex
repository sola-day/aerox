defmodule Aerox.AppView.Moderation do
  @moduledoc """
  The AppView's side of takedowns (DESIGN §15.6, §17.2): sets the
  `takedown_ref` hydration enforces on `appview.record` and
  `appview.actor`, and purges the image cache for a blob. Called in-node by
  the Labeler's actions (`Aerox.Labeler.Actions.Default`) when both
  services run in this node; account takedowns also arrive through the
  `#account` firehose event as `upstream_status`.
  """
  import Ecto.Query
  alias Aerox.AppView.Repo
  alias Aerox.AppView.Schema, as: S

  @doc "Whether the AppView runs in this node (its repo is up)."
  def enabled?, do: Process.whereis(Repo) != nil

  @spec set_record_takedown(String.t(), String.t() | nil) :: :ok
  def set_record_takedown(uri, ref) do
    Repo.update_all(from(r in S.Record, where: r.uri == ^uri), set: [takedown_ref: ref])
    :ok
  end

  @spec set_actor_takedown(String.t(), String.t() | nil) :: :ok
  def set_actor_takedown(did, ref) do
    Repo.update_all(from(a in S.Actor, where: a.did == ^did), set: [takedown_ref: ref])
    :ok
  end

  @doc "Drops every cached rendition of a blob (DESIGN §16)."
  @spec purge_blob(String.t(), String.t()) :: :ok
  def purge_blob(did, cid) do
    _ = Aerox.ImageServer.Cache.purge(did, cid)
    :ok
  end
end
