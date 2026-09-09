defmodule AeroxWeb.RouterParityTest do
  @moduledoc "VERIFICATION §7.1 item 3: the router and test/parity/ENDPOINTS.md agree exactly."
  use ExUnit.Case, async: true

  @table Path.expand("../parity/ENDPOINTS.md", __DIR__)
  @external_resource @table

  test "every routed XRPC method is in the parity table and vice versa" do
    routed =
      for %{path: "/xrpc/" <> method, verb: verb} <- Phoenix.Router.routes(AeroxWeb.Router),
          not String.starts_with?(method, "*"),
          do: {method, verb |> to_string() |> String.upcase()}

    listed =
      for line <- File.stream!(@table),
          [_, method, verb] <- [Regex.run(~r/^\| `([\w.]+)` \| (GET|POST) \|/, line)],
          do: {method, verb}

    assert routed != []
    assert Enum.sort(routed) -- Enum.sort(listed) == [], "routed but not in ENDPOINTS.md"
    assert Enum.sort(listed) -- Enum.sort(routed) == [], "in ENDPOINTS.md but not routed"
  end
end
