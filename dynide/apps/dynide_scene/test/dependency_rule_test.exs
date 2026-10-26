defmodule DynideScene.DependencyRuleTest do
  # Mix.Project.in_project changes VM-wide cwd and project stack
  use ExUnit.Case, async: false

  # The test-only integration app is the one exemption, by exact name.
  @integration_deps [:dynide_cli, :dynide_scene, :dynide_server, :dynide_term]

  test "every app depends on dynide_scene (and optionally dynide_reload); dynide_scene depends on nothing" do
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

    assert deps[:dynide_scene] == []

    assert deps[:dynide_integration] == @integration_deps,
           "dynide_integration must depend on exactly #{inspect(@integration_deps)}"

    assert deps[:dynide_reload] == [:dynide_scene],
           "dynide_reload must depend on dynide_scene only, got #{inspect(deps[:dynide_reload])}"

    for {app, d} <- deps, app not in [:dynide_scene, :dynide_reload, :dynide_integration] do
      assert d in [[:dynide_scene], [:dynide_reload, :dynide_scene]],
             "#{app} must depend on dynide_scene (and optionally dynide_reload), got #{inspect(d)}"
    end

    for app <- [:dynide_server, :dynide_term, :dynide_reload], do: assert(Map.has_key?(deps, app))
  end
end
