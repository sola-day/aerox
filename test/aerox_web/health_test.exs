defmodule AeroxWeb.HealthTest do
  @moduledoc """
  docs/OPS.md §4: the liveness path a monitor is pointed at. `/xrpc/_health` is
  where upstream's PDS answers, and on the PDS host it has to be declared ahead
  of the proxy catch-all of DESIGN §11.1 or the catch-all answers 501 instead.
  """
  use AeroxWeb.ConnCase, async: false

  setup do
    Aerox.RateLimit.reset()
    :ok
  end

  test "every service answers /xrpc/_health", %{conn: conn} do
    for {host, expected} <- [
          {Aerox.PDS.Config.hostname(), %{"version" => to_string(Application.spec(:aerox, :vsn))}},
          {Aerox.Relay.Config.hostname(), %{"status" => "ok"}},
          {Aerox.AppView.Config.hostname(), %{"status" => "ok"}},
          {Aerox.Labeler.Config.hostname(), %{"status" => "ok"}}
        ] do
      assert %{conn | host: host} |> get("/xrpc/_health") |> json_response(200) == expected,
             "#{host} did not answer /xrpc/_health"
    end
  end

  test "the PLC directory answers /_health, where did-method-plc puts it", %{conn: conn} do
    # The PLC shares the PDS router (AeroxWeb.Dispatch has no separate host for
    # it), and its own check also proves the directory's database is reachable.
    assert %{conn | host: Aerox.PDS.Config.hostname()}
           |> get("/_health")
           |> json_response(200) == %{"version" => to_string(Application.spec(:aerox, :vsn))}
  end
end
