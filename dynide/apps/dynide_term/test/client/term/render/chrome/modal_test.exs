defmodule DynideTerm.Client.Term.Render.Chrome.ModalTest do
  use ExUnit.Case, async: true

  alias DynideScene.{Cell, Fixture, Scene}
  alias DynideScene.Scene.Node
  alias DynideTerm.Cells
  alias DynideTerm.Client.Term.Render.{Chrome, Compose}
  alias DynideTerm.Client.Term.Theme

  @theme Theme.default()

  defp layout(scene), do: Chrome.layout(scene.chrome, scene.size, @theme)
  defp hit(layout, path), do: Enum.find(layout.hits, &(&1.path == path))

  defp texts(scene),
    do: scene |> Compose.frame(%{}, @theme) |> Enum.map(fn {_, b} -> Cells.to_text(b) end)

  defp cells(scene, y),
    do: scene |> Compose.frame(%{}, @theme) |> Enum.at(y) |> elem(1) |> Cell.decode_row()

  test "modal_prompt_80x24: a 56-wide box centred, title, input, buttons, dim and hits" do
    sc = Fixture.load("modal_prompt_80x24")
    l = layout(sc)
    assert l.dim
    t = texts(sc)
    box = Enum.map(8..14, &String.slice(Enum.at(t, &1), 12, 56))
    assert Enum.at(box, 0) == "┌" <> String.duplicate("─", 54) <> "┐"
    assert Enum.at(box, 6) == "└" <> String.duplicate("─", 54) <> "┘"
    assert Enum.at(box, 1) == "│" <> String.pad_trailing(" rename tab", 54) <> "│"
    assert Enum.at(box, 3) == "│" <> String.pad_trailing(" 1", 54) <> "│"

    buttons =
      String.duplicate(" ", 10) <> " ↵ save " <> "  " <> " ^c clear " <> "  " <> " esc cancel "

    assert Enum.at(box, 4) == "│" <> String.pad_trailing(buttons, 54) <> "│"
    # outside the box: untouched layout (the sidebar) on the same rows
    assert String.slice(Enum.at(t, 8), 0, 12) ==
             String.slice(Enum.at(texts(%{sc | chrome: base(sc)}), 8), 0, 12)

    assert hit(l, [{:modal, 1}, :actions, :save]).rect == %{x: 23, y: 12, w: 8, h: 1}
    assert hit(l, [{:modal, 1}, :actions, :clear]).rect == %{x: 33, y: 12, w: 10, h: 1}
    assert hit(l, [{:modal, 1}, :actions, :cancel]).rect == %{x: 45, y: 12, w: 12, h: 1}
    assert hit(l, [{:modal, 1}]).rect == %{x: 12, y: 8, w: 56, h: 7}
    assert hit(l, [{:modal, 1}, :backdrop]).rect == %{x: 0, y: 0, w: 80, h: 24}
    # topmost first: buttons, the panel, then the backdrop before any base hit
    paths = Enum.map(l.hits, & &1.path)
    assert Enum.find_index(paths, &(&1 == [{:modal, 1}, :backdrop])) == 4

    # border accent, panel and input on the surface, save primary, dim outside the box
    row = cells(sc, 12)
    assert Enum.at(row, 12).fg == Theme.style(@theme, :accent).fg
    assert Enum.at(row, 13).bg == Theme.style(@theme, :surface).bg
    assert Enum.at(row, 24).bg == Theme.style(@theme, :selected).bg
    refute :faint in Enum.at(row, 24).attrs
    assert :faint in Enum.at(row, 11).attrs
  end

  test "modal_confirm_80x24: 64x6 red border, title and detail, confirm and cancel" do
    sc = Fixture.load("modal_confirm_80x24")
    t = texts(sc)
    box = Enum.map(9..14, &String.slice(Enum.at(t, &1), 8, 64))
    assert Enum.at(box, 1) == "│" <> String.pad_trailing(" Close workspace?", 62) <> "│"
    assert Enum.at(box, 2) == "│" <> String.pad_trailing(" 1 — 1 pane", 62) <> "│"
    buttons = String.duplicate(" ", 18) <> " ↵ confirm " <> "  " <> " esc cancel "
    assert Enum.at(box, 4) == "│" <> String.pad_trailing(buttons, 62) <> "│"
    assert Enum.at(cells(sc, 9), 8).fg == Theme.style(@theme, :error).fg
    assert layout(sc).dim
  end

  test "menu_tab_80x24: entries at the click, the selected one highlighted, no dim" do
    sc = Fixture.load("menu_tab_80x24")
    l = layout(sc)
    refute l.dim
    %Node{rect: r} = Node.find(sc.chrome, [{:menu, 1}])
    assert r == %{x: 36, y: 0, w: 14, h: 5}
    t = texts(sc)
    assert String.slice(Enum.at(t, 0), 36, 14) == "┌" <> String.duplicate("─", 12) <> "┐"
    assert String.slice(Enum.at(t, 1), 36, 14) == "│ New tab    │"
    assert String.slice(Enum.at(t, 3), 36, 14) == "│ Close      │"
    assert Enum.at(cells(sc, 1), 38).bg == Theme.style(@theme, :selected).bg
    assert Enum.at(cells(sc, 2), 38).bg == Theme.style(@theme, :surface).bg
    assert hit(l, [{:menu, 1}, {:entry, :close}]).rect == %{x: 37, y: 3, w: 12, h: 1}
    assert hit(l, [{:menu, 1}, :backdrop]).rect == %{x: 0, y: 0, w: 80, h: 24}
  end

  test "menu_global_120x40 lists detach" do
    sc = Fixture.load("menu_global_120x40")
    assert Enum.any?(texts(sc), &(&1 =~ "│ detach"))
  end

  test "tiny modals and menus clip, keep the backdrop and compose to full-width rows" do
    for name <-
          ["modal_prompt_80x24", "modal_confirm_80x24", "menu_tab_80x24"] ++
            ["modal_settings_120x40", "modal_onboarding_80x24", "modal_keybinds_120x40"],
        cols <- [1, 3, 6, 20],
        rows <- [1, 3, 5] do
      sc = Fixture.load(name)
      [top] = Enum.filter(sc.chrome.children, &(&1.role in [:modal, :menu]))
      r = %{x: 0, y: 0, w: min(cols, top.rect.w), h: min(rows, top.rect.h)}

      sc = %Scene{
        size: %{cols: cols, rows: rows},
        chrome: %{sc.chrome | children: [%{top | rect: r}]}
      }

      l = layout(sc)
      assert hit(l, [top.id, :backdrop]).rect == %{x: 0, y: 0, w: cols, h: rows}
      frame = Compose.frame(sc, %{}, @theme)
      assert length(frame) == rows
      assert Enum.all?(frame, fn {_, b} -> Cell.cols(b) == cols end), "#{name} #{cols}x#{rows}"
    end
  end

  # inner text of a 76-wide panel at x 22 (120 columns)
  defp inner(t, y), do: t |> Enum.at(y) |> String.slice(23, 74) |> String.trim_trailing()

  test "modal_settings_120x40: section tabs and rule, heading, choices with marker, check and glyphs" do
    sc = Fixture.load("modal_settings_120x40")
    l = layout(sc)
    t = texts(sc)
    assert inner(t, 10) == " settings"
    assert inner(t, 11) == " theme   indicators   sound   toasts"
    assert inner(t, 12) == String.duplicate("─", 74)
    assert inner(t, 14) == " agent status indicators"
    assert inner(t, 15) == " choose color dots or distinct symbols for each state"
    assert inner(t, 17) == " ▸ color dots  ● ● ● ○ · ✓"
    assert inner(t, 18) == "   distinct symbols  × ◐ ✓ ○ ·"
    assert inner(t, 28) == " ↑↓ select  tab section"
    assert inner(t, 29) =~ "↵ apply    esc close"

    # active tab and the selected choice on :selected, the others on the surface
    assert Enum.at(cells(sc, 11), 31).bg == Theme.style(@theme, :selected).bg
    assert Enum.at(cells(sc, 11), 24).bg == Theme.style(@theme, :surface).bg
    assert Enum.at(cells(sc, 17), 30).bg == Theme.style(@theme, :selected).bg
    assert Enum.at(cells(sc, 18), 30).bg == Theme.style(@theme, :surface).bg

    assert hit(l, [{:modal, 1}, :sections, {:section, :indicators}]).rect ==
             %{x: 31, y: 11, w: 12, h: 1}

    assert hit(l, [{:modal, 1}, :list, {:choice, 1}]).rect == %{x: 23, y: 18, w: 74, h: 1}
    assert hit(l, [{:modal, 1}, :actions, :apply])
  end

  test "modal_onboarding_80x24: dynide lines, prefix keycaps in the accent, continue" do
    sc = Fixture.load("modal_onboarding_80x24")
    t = texts(sc)
    box = Enum.map(4..19, &String.slice(Enum.at(t, &1), 8, 64))
    assert Enum.at(box, 1) == "│" <> String.pad_trailing(" dynIDE", 62) <> "│"
    assert Enum.at(box, 4) =~ "│ this is a mouse-first terminal."
    line = " ctrl+b enters prefix mode · ? shows keybinds and settings"
    assert Enum.at(box, 8) == "│" <> String.pad_trailing(line, 62) <> "│"
    assert Enum.at(box, 14) =~ "↵ continue"
    assert Enum.at(cells(sc, 12), 10).fg == Theme.style(@theme, :accent).fg
    assert :bold in Enum.at(cells(sc, 12), 10).attrs
    assert hit(layout(sc), [{:modal, 1}, :actions, :continue]).rect.y == 18
  end

  test "modal_keybinds_120x40: group headings, shortcut column, rows as hits" do
    sc = Fixture.load("modal_keybinds_120x40")
    t = texts(sc)
    assert inner(t, 10) == " keybinds"
    assert inner(t, 11) == " press / to filter by command or shortcut"
    assert inner(t, 13) == " global"
    assert inner(t, 14) == " prefix+?         keybinds"
    assert inner(t, 23) == " prefix+tab       cycle pane next"
    assert inner(t, 28) == " search / · scroll j/k/↑↓/pgup/pgdn · rebind enter · close esc"
    # the second action is selected
    assert Enum.at(cells(sc, 15), 30).bg == Theme.style(@theme, :selected).bg
    assert Enum.at(cells(sc, 14), 24).fg == Theme.style(@theme, :accent).fg

    assert hit(layout(sc), [{:modal, 1}, :list, {:action, "detach"}]).rect ==
             %{x: 23, y: 16, w: 74, h: 1}
  end

  test "modal_keybind_capture_120x40: the capture subtitle" do
    t = texts(Fixture.load("modal_keybind_capture_120x40"))
    assert inner(t, 11) == " press a key for rename_tab · esc cancels"
    assert Enum.any?(t, &(&1 =~ "prefix+shift+t   rename tab"))
  end

  defp base(sc),
    do: %{sc.chrome | children: Enum.reject(sc.chrome.children, &(&1.role == :modal))}
end
