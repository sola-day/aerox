Code.require_file("helpers.exs", __DIR__)

defmodule Aerox.Labeler.FetchLabelsTest do
  @moduledoc "com.atproto.temp.fetchLabels (deprecated; ozone's): labels created after `since`, oldest first."
  use AeroxWeb.ConnCase, async: false

  setup %{conn: conn} do
    Aerox.LabelerTestHelpers.configure_unit_labeler!()
    {:ok, conn: %{conn | host: Aerox.Labeler.Config.hostname()}}
  end

  test "since in epoch milliseconds, oldest first", %{conn: conn} do
    {:ok, l1} =
      Aerox.Labeler.Labels.create(%{uri: "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa", val: "spam"})

    Process.sleep(5)

    {:ok, l2} =
      Aerox.Labeler.Labels.create(%{uri: "did:plc:bbbbbbbbbbbbbbbbbbbbbbbb", val: "spam"})

    uris = fn query ->
      conn
      |> get("/xrpc/com.atproto.temp.fetchLabels?" <> URI.encode_query(query))
      |> json_response(200)
      |> Map.get("labels")
      |> Enum.map(& &1["uri"])
    end

    assert Enum.take(uris.(%{}), -2) == [l1.uri, l2.uri]
    after_l1 = uris.(%{since: DateTime.to_unix(l1.cts, :millisecond)})
    refute l1.uri in after_l1
    assert l2.uri in after_l1
    assert conn |> get("/xrpc/com.atproto.temp.fetchLabels?limit=0") |> json_response(400)
  end
end
