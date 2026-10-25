defmodule HerdrScene.DependencyRuleTest do
  # Mix.Project.in_project changes VM-wide cwd and project stack
  use ExUnit.Case, async: false

  # The test-only integration app is the one exemption, by exact name.
  @integration_deps [:herdr_cli, :herdr_scene, :herdr_server, :herdr_term]

  test "every app depends on herdr_scene (and optionally herdr_reload); herdr_scene depends on nothing" do
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
          for(
            {name, opts} <- config[:deps],
            is_list(opts) and opts[:in_umbrella] == true,
            do: name
          )
          |> Enum.sort()

        {app, in_umbrella}
      end

    assert deps[:herdr_scene] == []

    assert deps[:herdr_integration] == @integration_deps,
           "herdr_integration must depend on exactly #{inspect(@integration_deps)}"

    assert deps[:herdr_reload] == [:herdr_scene],
           "herdr_reload must depend on herdr_scene only, got #{inspect(deps[:herdr_reload])}"

    for {app, d} <- deps, app not in [:herdr_scene, :herdr_reload, :herdr_integration] do
      assert d in [[:herdr_scene], [:herdr_reload, :herdr_scene]],
             "#{app} must depend on herdr_scene (and optionally herdr_reload), got #{inspect(d)}"
    end

    for app <- [:herdr_server, :herdr_term, :herdr_reload], do: assert(Map.has_key?(deps, app))
  end
end
