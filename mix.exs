defmodule Aerox.MixProject do
  use Mix.Project

  def project do
    [
      app: :aerox,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:boundary, :phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      boundary: [externals_mode: :relaxed],
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/project.plt"},
        plt_add_apps: [:mix, :ex_unit]
      ]
    ]
  end

  def application do
    [
      mod: {Aerox.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        "aerox.interop.from_pds": :tool,
        "aerox.interop.to_pds": :tool
      ]
    ]
  end

  # STRUCTURE §5: `lib_tool/` is compiled only in dev, test and tool. A prod
  # release must not contain the SQLite driver or any module that names it.
  defp elixirc_paths(:test), do: ["lib", "lib_tool", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "lib_tool"]
  defp elixirc_paths(:tool), do: ["lib", "lib_tool"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # web
      {:phoenix, "~> 1.8.13"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:mint_web_socket, "~> 1.0"},
      {:broadway, "~> 1.3"},
      {:b3, "~> 0.2.1"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:websock_adapter, "~> 0.5"},
      # kernel (DESIGN §3.8: secp256k1 via a Rust NIF, never hand-rolled)
      {:ex_secp256k1, "~> 0.8.0"},
      # auth (DESIGN §13.4: upstream-compatible scrypt via a C NIF)
      {:scrypt, "~> 2.1"},
      # image CDN (DESIGN §16: libvips via a NIF, the deliberate §3.9 exception)
      {:vix, "~> 0.41"},
      # shared infrastructure
      {:jose, "~> 1.11"},
      {:oban, "~> 2.24"},
      {:hammer, "~> 7.5"},
      # architecture enforcement (STRUCTURE §6)
      {:boundary, "~> 0.10.4", runtime: false},
      # tool-only: the reference-PDS SQLite adapter (DESIGN §13.2)
      {:exqlite, "~> 0.40", only: [:dev, :test, :tool]},
      # test and quality
      {:stream_data, "~> 1.4", only: [:dev, :test]},
      {:mox, "~> 1.3", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.create", "ecto.migrate"],
      test: ["ecto.migrate --quiet", "test"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo",
        "test"
      ]
    ]
  end
end
