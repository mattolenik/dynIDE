defmodule HerdrServer.SceneFixturesTest do
  use ExUnit.Case, async: true

  alias HerdrScene.{Fixture, Scene}
  alias HerdrServer.App.Actions
  alias HerdrServer.Client.State
  alias HerdrServer.View

  @dir Path.expand("../../herdr_scene/priv/fixtures/scenes", __DIR__)

  @fixtures [
    {"single_pane_80x24", {80, 24}, []},
    {"two_pane_split_120x40", {120, 40}, [:v]},
    {"three_pane_l_shape_100x30", {100, 30}, [:v, :h]},
    {"prefix_mode_status_80x24", {80, 24}, [:prefix]},
    {"two_tabs_80x24", {80, 24}, [:c]},
    {"narrow_15_panes_200x50", {200, 50}, [{:many, 15}]}
  ]

  for {name, size, steps} <- @fixtures do
    test name do
      {cols, rows} = unquote(Macro.escape(size))
      steps = unquote(Macro.escape(steps))
      app = build(cols, rows, steps)
      # the prefix step is client input state, not app state
      mode = if :prefix in steps, do: :prefix, else: :terminal
      client = %State{size: %{cols: cols, rows: rows}, transport: :ref, mode: mode}
      scene = View.compute(app, client)
      assert :ok = Scene.validate(scene)

      if System.get_env("HERDR_UPDATE_FIXTURES") == "1" do
        Fixture.dump(unquote(name), scene, @dir)
      else
        assert scene == Fixture.load(unquote(name), @dir)
      end
    end
  end

  test "no orphaned fixtures" do
    assert Fixture.names(@dir) == @fixtures |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  end

  test "narrow fixture has 15 positive content rects" do
    scene = View.compute(build(200, 50, [{:many, 15}]), %State{size: %{cols: 200, rows: 50}})
    assert length(scene.panes) == 15
    assert Enum.all?(scene.panes, &(&1.rect.w > 0 and &1.rect.h > 0))
  end

  defp build(cols, rows, steps) do
    app = elem(Actions.init(%{cols: cols, rows: rows}), 0)
    Enum.reduce(steps, app, &step/2)
  end

  defp step(:v, app), do: HerdrServer.ViewHelpers.pfx(app, "v")
  defp step(:h, app), do: HerdrServer.ViewHelpers.pfx(app, "-")
  defp step(:c, app), do: HerdrServer.ViewHelpers.pfx(app, "c")
  defp step(:prefix, app), do: app
  defp step({:many, n}, app), do: HerdrServer.ViewHelpers.many(app, n)
end
