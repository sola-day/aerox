defmodule Aerox.RepoBoundaryTest do
  @moduledoc """
  DESIGN §4.6: the service boundary is enforced by the database, not by
  convention. Each repo connects as its own role and must be unable to read
  another service's schema, and the PDS database must be unreachable from the
  core roles altogether.
  """
  use Aerox.DataCase, async: true

  test "the AppView role cannot read the relay or plc schemas" do
    for schema <- ["relay", "plc"] do
      assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
               Aerox.AppView.Repo.query("SELECT 1 FROM #{schema}.schema_migrations")
    end
  end

  test "the Relay role cannot read the appview schema" do
    assert {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} =
             Aerox.Relay.Repo.query("SELECT 1 FROM appview.oban_jobs")
  end

  test "each core repo resolves unqualified names in its own schema" do
    for {repo, schema} <- [
          {Aerox.PLC.Repo, "plc"},
          {Aerox.Relay.Repo, "relay"},
          {Aerox.AppView.Repo, "appview"}
        ] do
      assert {:ok, %{rows: [[^schema]]}} = repo.query("SELECT current_schema()")
    end
  end

  test "the core roles cannot connect to the PDS database" do
    pds = Aerox.PDS.Repo.config()

    for role <- ["aerox_plc", "aerox_relay", "aerox_appview"] do
      opts =
        pds
        |> Keyword.take([:hostname, :port, :database])
        |> Keyword.merge(
          username: role,
          password: role,
          backoff_type: :stop,
          show_sensitive_data_on_connection_error: true
        )

      # Postgrex logs the refusal and stops; the observable fact is that no
      # connection ever becomes usable for that role.
      Process.flag(:trap_exit, true)
      {:ok, pid} = Postgrex.start_link(opts)
      assert_receive {:EXIT, ^pid, _reason}, 5_000
    end
  end
end
