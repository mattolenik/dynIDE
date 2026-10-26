defmodule DynideIntegration.MixProject do
  use Mix.Project

  def project do
    [
      app: :dynide_integration,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:dynide_cli, in_umbrella: true},
      {:dynide_scene, in_umbrella: true},
      {:dynide_server, in_umbrella: true},
      {:dynide_term, in_umbrella: true}
    ]
  end
end
