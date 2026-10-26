defmodule DynideServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :dynide_server,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {DynideServer.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:dynide_scene, in_umbrella: true},
      {:dynide_reload, in_umbrella: true},
      {:rustler, "~> 0.38.0", runtime: false},
      {:toml, "~> 0.7"},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
