defmodule HerdrServer.SceneFixturesTest do
  use ExUnit.Case, async: true

  alias HerdrScene.{Event, Fixture, Scene}
  alias HerdrServer.App.Actions
  alias HerdrServer.App.Modal.{Confirm, Onboarding, Prompt, Settings}
  alias HerdrServer.App.Modal.Keybinds, as: KeybindsModal
  alias HerdrServer.Client.State
  alias HerdrServer.View

  @dir Path.expand("../../herdr_scene/priv/fixtures/scenes", __DIR__)

  @fixtures [
    {"single_pane_80x24", {80, 24}, []},
    {"two_pane_split_120x40", {120, 40}, [:v]},
    {"three_pane_l_shape_100x30", {100, 30}, [:v, :h]},
    {"prefix_mode_status_80x24", {80, 24}, [:prefix]},
    {"two_tabs_80x24", {80, 24}, [:c]},
    {"narrow_15_panes_200x50", {200, 50}, [{:many, 15}]},
    {"sidebar_expanded_120x40", {120, 40}, [:v]},
    {"sidebar_collapsed_80x24", {80, 24}, [:b]},
    {"two_workspaces_120x40", {120, 40}, [:c, {:workspace, "two"}]},
    {"modal_confirm_80x24", {80, 24}, [:confirm]},
    {"modal_prompt_80x24", {80, 24}, [:prompt]},
    {"menu_tab_80x24", {80, 24}, [:c, {:right_click, [:tabs, {:tab, 2}], 36, 0}]},
    {"menu_global_120x40", {120, 40}, [{:click, [:sidebar, :spaces, :menu], 20, 36}]},
    {"modal_settings_120x40", {120, 40}, [{:open, Settings}, {:key, :tab}]},
    {"modal_onboarding_80x24", {80, 24}, [:onboarding]},
    {"modal_keybinds_120x40", {120, 40}, [{:open, KeybindsModal}, {:key, "j"}]},
    {"modal_keybind_capture_120x40", {120, 40},
     [{:open, KeybindsModal}, {:click, [{:modal, 0}, :list, {:action, "rename_tab"}], 0, 0}]},
    {"toast_120x40", {120, 40}, [:c, :toast]}
  ]

  for {name, size, steps} <- @fixtures do
    test name do
      {cols, rows} = unquote(Macro.escape(size))
      steps = unquote(Macro.escape(steps))
      app = build(cols, rows, steps)
      # the prefix step is client input state, not app state
      mode = if :prefix in steps, do: :prefix, else: :terminal
      # so is a toast: one for pane 1, in the background tab
      toasts =
        if :toast in steps,
          do: [
            %{id: 1, level: :attention, title: "pi needs attention", body: "1 · 1 · 1", pane: 1}
          ],
          else: []

      client = %State{
        size: %{cols: cols, rows: rows},
        transport: :ref,
        mode: mode,
        toasts: toasts
      }

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
  # a tab without the new-tab name prompt
  defp step(:c, app), do: elem(Actions.new_tab(app), 0)
  defp step(:confirm, app), do: elem(Confirm.close_workspace(app), 0)
  defp step(:prompt, app), do: elem(Prompt.rename_tab(app), 0)

  defp step({kind, path, x, y}, app),
    do: elem(Actions.apply(app, {:chrome, path, {kind, %{x: x, y: y}}}), 0)

  defp step({:open, mod}, app), do: elem(mod.open(app), 0)
  defp step({:key, k}, app), do: elem(Actions.apply(app, Event.key(k)), 0)
  defp step(:onboarding, app), do: Onboarding.at_start(put_in(app.ui.onboarding, true))
  defp step(:b, app), do: HerdrServer.ViewHelpers.pfx(app, "b")
  defp step({:workspace, name}, app), do: HerdrServer.ViewHelpers.add_workspace(app, name)
  defp step(:prefix, app), do: app
  defp step(:toast, app), do: app
  defp step({:many, n}, app), do: HerdrServer.ViewHelpers.many(app, n)
end
