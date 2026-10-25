defmodule HerdrCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :herdr_cli,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # No application callback: the CLI runs as `erl -run Elixir.HerdrCli main_erl`
  # (see bin/herdr-live) and only needs its own ebin and Elixir's; `update` (HerdrCli.Update)
  # also uses crypto, and inets/ssl/public_key for http(s) manifests.
  def application, do: [extra_applications: [:crypto, :inets, :ssl, :public_key]]

  defp deps do
    [{:herdr_scene, in_umbrella: true}]
  end
end
