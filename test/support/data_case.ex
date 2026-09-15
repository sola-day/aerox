defmodule Aerox.DataCase do
  @moduledoc """
  Sandboxed access to every repo (VERIFICATION §0 rule 5: real Postgres, two
  databases, Ecto sandbox). `use Aerox.DataCase, repos: [Aerox.PDS.Repo]` limits
  the sandbox to the repos a test needs; the default checks out all four.
  """
  use Boundary, top_level?: true, deps: [Aerox.PDS, Aerox.PLC, Aerox.Relay, Aerox.AppView]
  use ExUnit.CaseTemplate

  @repos [
    Aerox.PDS.Repo,
    Aerox.PLC.Repo,
    Aerox.Relay.Repo,
    Aerox.AppView.Repo,
    Aerox.Labeler.Repo,
    Aerox.Jetstream.Repo
  ]

  using opts do
    quote do
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Aerox.DataCase

      @repos unquote(opts[:repos] || @repos)

      setup tags do
        Aerox.DataCase.setup_sandbox(@repos, tags)
        :ok
      end
    end
  end

  def all_repos, do: @repos

  def setup_sandbox(repos, tags) do
    for repo <- repos do
      pid = Ecto.Adapters.SQL.Sandbox.start_owner!(repo, shared: not tags[:async])
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    end
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
