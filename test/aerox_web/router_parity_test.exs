defmodule AeroxWeb.RouterParityTest do
  @moduledoc "VERIFICATION §7.1 item 3: the four routers and test/parity/ENDPOINTS.md agree exactly."
  use ExUnit.Case, async: true

  @table Path.expand("../parity/ENDPOINTS.md", __DIR__)
  @external_resource @table
  @routers [
    {AeroxWeb.Router, "pds"},
    {AeroxWeb.RelayRouter, "relay"},
    {AeroxWeb.AppViewRouter, "appview"},
    {AeroxWeb.LabelerRouter, "labeler"}
  ]

  test "every routed XRPC method is in the parity table for its service, and vice versa" do
    routed =
      for {router, service} <- @routers,
          %{path: "/xrpc/" <> method, verb: verb} <- Phoenix.Router.routes(router),
          not String.starts_with?(method, "*"),
          verb != :options,
          do: {method, verb |> to_string() |> String.upcase(), service}

    listed =
      for line <- File.stream!(@table),
          [_, method, verb, service] <- [
            Regex.run(~r/^\| `([\w.]+)` \| (GET|POST) \| (\w+) \|/, line)
          ],
          do: {method, verb, service}

    assert routed != []
    assert Enum.sort(routed) -- Enum.sort(listed) == [], "routed but not in ENDPOINTS.md"
    assert Enum.sort(listed) -- Enum.sort(routed) == [], "in ENDPOINTS.md but not routed"
  end
end
