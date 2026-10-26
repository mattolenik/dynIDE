defmodule DynideTerm.Client.Term.ThemeTest do
  use ExUnit.Case, async: true

  alias DynideScene.Scene
  alias DynideTerm.Client.Term.Theme
  alias DynideTerm.Client.Term.Theme.Palettes

  test "every palette has 19 slots and resolves every token" do
    assert length(Palettes.names()) == 18

    for name <- Palettes.names() do
      p = Palettes.get(name)
      assert map_size(p) == 19
      theme = Theme.resolve(p)
      for t <- Scene.tokens(), do: assert(%{} = Theme.style(theme, t))
      assert Map.keys(theme.styles) |> Enum.sort() == Enum.sort(Scene.tokens())
    end
  end

  test "for_scene: auto_switch picks light/dark names, else name; unknown is catppuccin" do
    props = %{name: "nord", auto_switch: true, light: "gruvbox-light", dark: "dracula"}
    assert Theme.for_scene(props, :light) == Theme.resolve(Palettes.get("gruvbox-light"))
    assert Theme.for_scene(props, :dark) == Theme.resolve(Palettes.get("dracula"))
    assert Theme.for_scene(props, nil) == Theme.for_scene(props, :dark)
    off = %{props | auto_switch: false}
    assert Theme.for_scene(off, :light) == Theme.resolve(Palettes.get("nord"))

    assert Theme.for_scene(%{off | name: "nope"}, :dark) ==
             Theme.resolve(Palettes.get("catppuccin"))

    assert Theme.for_scene(%{off | name: "Tokyo_Night"}, :dark).styles.accent.fg ==
             Palettes.get("tokyo-night").accent
  end

  test "token mapping and the terminal palette's ANSI indexes" do
    t = Theme.for_scene(%{name: "catppuccin", auto_switch: false, light: "", dark: ""}, :dark)
    p = Palettes.get("catppuccin")
    assert Theme.style(t, :selected) |> Map.take([:fg, :bg]) == %{fg: p.panel_bg, bg: p.accent}
    assert Theme.style(t, :surface).bg == p.surface0
    assert Theme.style(t, :strong).attrs == [:bold]
    term = Theme.resolve(Palettes.get("terminal"))
    assert Theme.style(term, :accent).fg == {:palette, 4}
    assert Theme.style(term, :default).fg == :default
  end

  test "default/0 keeps the M3 look" do
    assert Theme.style(Theme.default(), :accent).fg == {:palette, 4}
  end
end
