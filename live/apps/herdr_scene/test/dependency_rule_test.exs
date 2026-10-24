defmodule HerdrScene.DependencyRuleTest do
  # Mix.Project.in_project changes VM-wide cwd and project stack
  use ExUnit.Case, async: false

  # The test-only integration app is the one exemption, by exact name.
  @integration_deps [:herdr_scene, :herdr_server, :herdr_term]

  test "every app depends on herdr_scene only; herdr_scene depends on nothing" do
    deps =
      for mix_exs <- Path.wildcard(Path.expand("../../../apps/*/mix.exs", __DIR__)), into: %{} do
        dir = Path.dirname(mix_exs)
        app = dir |> Path.basename() |> String.to_atom()

        # The running project is already loaded; Mix refuses to load it twice.
        config =
          if Mix.Project.config()[:app] == app,
            do: Mix.Project.config(),
            else: Mix.Project.in_project(app, dir, fn _ -> Mix.Project.config() end)

        assert config[:consolidate_protocols] == (Mix.env() == :prod),
               "#{app} must set consolidate_protocols: Mix.env() == :prod"

        in_umbrella =
          for {name, opts} <- config[:deps],
              is_list(opts) and opts[:in_umbrella] == true,
              do: name

        {app, in_umbrella}
      end

    assert deps[:herdr_scene] == []

    assert deps[:herdr_integration] == @integration_deps,
           "herdr_integration must depend on exactly #{inspect(@integration_deps)}"

    for {app, d} <- deps, app not in [:herdr_scene, :herdr_integration] do
      assert d == [:herdr_scene], "#{app} must depend on herdr_scene only, got #{inspect(d)}"
    end

    assert Map.has_key?(deps, :herdr_server) and Map.has_key?(deps, :herdr_term)
  end
end
