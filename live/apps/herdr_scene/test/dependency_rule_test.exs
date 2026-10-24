defmodule HerdrScene.DependencyRuleTest do
  use ExUnit.Case, async: true

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

        in_umbrella =
          for {name, opts} <- config[:deps],
              is_list(opts) and opts[:in_umbrella] == true,
              do: name

        {app, in_umbrella}
      end

    assert deps[:herdr_scene] == []

    for {app, d} <- deps, app != :herdr_scene do
      assert d == [:herdr_scene], "#{app} must depend on herdr_scene only, got #{inspect(d)}"
    end

    assert Map.has_key?(deps, :herdr_server) and Map.has_key?(deps, :herdr_term)
  end
end
