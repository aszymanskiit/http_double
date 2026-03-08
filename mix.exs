defmodule HttpDouble.MixProject do
  use Mix.Project

  @source_url "https://github.com/aszymanskiit/http_double"
  @version "0.1.0"

  def project do
    [
      app: :http_double,
      version: @version,
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: dialyzer(),
      elixirc_paths: elixirc_paths(Mix.env()),
      source_url: @source_url,
      package: package(),
      description:
        "Controllable dummy HTTP server for integration testing (ejabberd/XMPP-friendly)",
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.html": :test,
        "coveralls.lcov": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {HttpDouble.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:plug_cowboy, "~> 2.5"},
      {:jason, "~> 1.4"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false}
    ]
  end

  defp dialyzer do
    [
      plt_add_deps: :app_tree,
      ignore_warnings: "dialyzer.ignore-warnings"
    ]
  end

  defp package do
    [
      maintainers: ["aszymanskiit"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
