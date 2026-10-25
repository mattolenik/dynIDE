defmodule HerdrSceneHtml.MixProject do
  use Mix.Project

  def project do
    [
      app: :herdr_scene_html,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() == :prod,
      deps: [{:herdr_scene, in_umbrella: true}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
