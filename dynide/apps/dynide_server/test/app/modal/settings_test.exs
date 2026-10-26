defmodule DynideServer.App.Modal.SettingsTest do
  use ExUnit.Case, async: true

  alias DynideScene.Event
  alias DynideScene.Scene.Node
  alias DynideServer.App.{Actions, Modal}
  alias DynideServer.App.Modal.Settings

  defp fresh, do: elem(Actions.init(%{cols: 120, rows: 40}), 0)
  defp open, do: elem(Settings.open(fresh()), 0)
  defp key(app, k, mods \\ []), do: Actions.apply(app, Event.key(k, mods))
  defp press(app, k, mods \\ []), do: elem(key(app, k, mods), 0)

  defp click(app, path),
    do: Actions.apply(app, {:chrome, [{:modal, 1} | path], {:click, %{x: 0, y: 0}}})

  defp view(app), do: Modal.view(app, app.session.size)

  defp items(app),
    do: Node.find(view(app), [:list]).children |> Enum.filter(&(&1.role == :item))

  test "opens on the theme section with the current theme selected" do
    app = open()
    assert %{kind: :settings, section: :theme, cursor: 0} = Modal.top(app)
    n = view(app)
    assert n.props.kind == :settings
    assert Node.find(n, [:title]).text == "settings"
    tabs = Node.find(n, [:sections]).children
    assert Enum.map(tabs, & &1.text) == ["theme", "indicators", "sound", "toasts"]
    assert Enum.map(tabs, & &1.props.active) == [true, false, false, false]
    assert [%Node{text: "catppuccin", props: %{selected: true, current: true}} | _] = items(app)
    assert Node.find(n, [:hint]).text == "↑↓ select  tab section"
    assert Enum.map(Node.find(n, [:actions]).children, & &1.id) == [:apply, :close]
  end

  test "the 18 herdr themes are the theme choices" do
    assert length(Settings.themes()) == 18
    assert hd(Settings.themes()) == "catppuccin"
    assert List.last(Settings.themes()) == "vesper"
  end

  test "indicators: Down then Enter selects symbols, sets ui.indicators and writes the config" do
    app = press(open(), :tab)
    n = view(app)
    assert Node.find(n, [:heading]).text == "agent status indicators"

    assert Node.find(n, [:description]).text ==
             "choose color dots or distinct symbols for each state"

    assert Enum.map(items(app), & &1.text) == ["color dots", "distinct symbols"]
    assert Enum.map(items(app), & &1.props.indicators) == [:dots, :symbols]
    app = press(app, :down)
    {app, effects} = key(app, :enter)
    assert app.ui.indicators == :symbols
    assert effects == [{:config_write, ["ui"], %{"status_indicators" => "symbols"}}]
    assert %{kind: :settings} = Modal.top(app)
    assert Enum.map(items(app), & &1.props.current) == [false, true]
  end

  test "theme cursor previews the theme; Esc restores the original" do
    app = press(open(), :down)
    assert app.ui.theme.name == "catppuccin-latte"
    app = press(app, "j")
    assert app.ui.theme.name == "terminal"
    app = press(app, :up)
    assert app.ui.theme.name == "catppuccin-latte"
    {app, []} = key(app, :escape)
    assert app.focus.modal == []
    assert app.ui.theme.name == "catppuccin"
  end

  test "theme apply writes [theme] name with auto_switch off and closes" do
    app = put_in(open().ui.theme.auto_switch, true)
    app = press(app, :down)
    {app, effects} = key(app, " ")

    assert effects == [
             {:config_write, ["theme"], %{"name" => "catppuccin-latte", "auto_switch" => false}}
           ]

    assert app.ui.theme.name == "catppuccin-latte" and app.ui.theme.auto_switch == false
    assert app.focus.modal == []
  end

  test "leaving the theme section restores a previewed theme" do
    app = open() |> press(:down) |> press(:right)
    assert app.ui.theme.name == "catppuccin"
    assert Modal.top(app).section == :indicators
  end

  test "sound and toasts write their tables; sections wrap both ways" do
    app = open() |> press(:tab) |> press(:tab)
    assert Node.find(view(app), [:heading]).text == "sound alerts"
    assert Enum.map(items(app), & &1.text) == ["on", "off"]
    {app, effects} = app |> press(:down) |> key(:enter)
    assert app.ui.sound.enabled == false
    assert effects == [{:config_write, ["ui", "sound"], %{"enabled" => false}}]

    app = open() |> press(:tab, [:shift])
    assert Modal.top(app).section == :toasts
    assert Node.find(view(app), [:heading]).text == "notification popups"

    assert Enum.map(items(app), & &1.text) == [
             "off",
             "inside dynIDE",
             "via terminal",
             "via system"
           ]

    # current delivery (herdr) is selected first
    assert Modal.top(app).cursor == 1
    {app, effects} = app |> press("k") |> key(:enter)
    assert app.ui.toast.delivery == :off
    assert effects == [{:config_write, ["ui", "toast"], %{"delivery" => "off"}}]
    assert Modal.top(press(app, "l")).section == :theme
    assert Modal.top(press(app, "h")).section == :sound
  end

  test "clicks: a section tab switches, a choice selects, apply applies, close restores" do
    {app, []} = click(open(), [:sections, {:section, :sound}])
    assert Modal.top(app).section == :sound
    {app, []} = click(app, [:sections, {:section, :theme}])
    {app, []} = click(app, [:list, {:choice, 3}])
    assert app.ui.theme.name == "tokyo-night"
    {app, []} = click(app, [:actions, :close])
    assert app.focus.modal == [] and app.ui.theme.name == "catppuccin"

    {app, []} = click(open(), [:sections, {:section, :indicators}])
    {app, []} = click(app, [:list, {:choice, 1}])
    {app, [{:config_write, ["ui"], _}]} = click(app, [:actions, :apply])
    assert app.ui.indicators == :symbols
  end

  test "a backdrop click closes and restores the previewed theme" do
    app = press(open(), :down)
    {app, []} = Actions.apply(app, {:chrome, [{:modal, 1}, :backdrop], {:click, %{x: 0, y: 0}}})
    assert app.focus.modal == [] and app.ui.theme.name == "catppuccin"
  end

  test "the theme list scrolls to keep the cursor visible" do
    app = Enum.reduce(1..17, open(), fn _, a -> press(a, :down) end)
    assert app.ui.theme.name == "vesper"
    its = items(app)
    assert List.last(its).text == "vesper" and List.last(its).props.selected
    assert length(its) == Node.find(view(app), [:list]).props.rows
  end
end
