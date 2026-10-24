defmodule Live.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # :mix for Reload's in-VM compiler and the `mix herdr_term.demo` task;
      # :ex_unit for test-only modules.
      dialyzer: [plt_core_path: "_build/#{Mix.env()}", plt_add_apps: [:mix, :ex_unit]]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
