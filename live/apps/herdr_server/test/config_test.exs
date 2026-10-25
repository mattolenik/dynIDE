defmodule HerdrServer.ConfigTest do
  # path/0 reads the application env and the OS env
  use ExUnit.Case, async: false

  alias HerdrServer.App.{Actions, Keybinds, Ui}
  alias HerdrServer.App.Modal.Prompt
  alias HerdrServer.Config
  alias HerdrServer.Plugins.Keybind

  @moduletag :tmp_dir

  defp load(dir, toml) do
    path = Path.join(dir, "config.toml")
    File.write!(path, toml)
    Config.load(path)
  end

  defp ui, do: %Ui{keybinds: Keybinds.default()}

  defp apply_cfg(cfg, opts \\ []), do: Config.apply(cfg, Keybinds.default(), ui(), opts)

  describe "path/0" do
    setup do
      saved = Application.get_env(:herdr_server, :config_path)
      env = for v <- ~w(HERDR_LIVE_CONFIG XDG_CONFIG_HOME), into: %{}, do: {v, System.get_env(v)}
      Application.delete_env(:herdr_server, :config_path)

      on_exit(fn ->
        Application.put_env(:herdr_server, :config_path, saved)

        for {k, v} <- env,
            do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
      end)
    end

    test "app env, then HERDR_LIVE_CONFIG, then XDG_CONFIG_HOME, then ~/.config" do
      System.delete_env("HERDR_LIVE_CONFIG")
      System.delete_env("XDG_CONFIG_HOME")
      assert Config.path() == Path.join(System.user_home!(), ".config/herdr-live/config.toml")
      System.put_env("XDG_CONFIG_HOME", "/x")
      assert Config.path() == "/x/herdr-live/config.toml"
      System.put_env("HERDR_LIVE_CONFIG", "/y/c.toml")
      assert Config.path() == "/y/c.toml"
      Application.put_env(:herdr_server, :config_path, "/z.toml")
      assert Config.path() == "/z.toml"
    end
  end

  test "a missing file is the defaults with onboarding", %{tmp_dir: dir} do
    cfg = Config.load(Path.join(dir, "nope.toml"))
    assert %{onboarding: true, diagnostics: [], keys: %{}, ui: %{}, theme: %{}} = cfg
    {kb, ui, []} = apply_cfg(cfg)
    assert kb == Keybinds.default()
    assert ui.onboarding
  end

  test "[keys] new_tab binds the new key and keeps the other defaults", %{tmp_dir: dir} do
    cfg = load(dir, "onboarding = false\n[keys]\nnew_tab = \"prefix+t\"\n")
    assert cfg.onboarding == false
    {kb, ui, []} = apply_cfg(cfg)
    assert Keybinds.lookup(kb, :prefix, {"t", []}) == {Prompt, :new_tab, []}
    assert Keybinds.lookup(kb, :prefix, {"c", []}) == nil

    assert Map.delete(kb.prefix_binds, {"t", []}) ==
             Map.delete(Keybinds.default().prefix_binds, {"c", []})

    refute ui.onboarding
  end

  test "arrays, the prefix and direct binds", %{tmp_dir: dir} do
    toml = """
    [keys]
    prefix = "ctrl+a"
    next_tab = ["prefix+n", "alt+n"]
    detach = []
    """

    {kb, _ui, []} = apply_cfg(load(dir, toml))
    assert kb.prefix == [{"a", [:ctrl]}]
    assert Keybinds.lookup(kb, :prefix, {"n", []}) == {Actions, :next_tab, []}
    assert Keybinds.lookup(kb, :terminal, {"n", [:alt]}) == {Actions, :next_tab, []}
    assert Keybinds.lookup(kb, :prefix, {"q", []}) == nil
    assert Keybinds.to_config(kb)["prefix"] == ["ctrl+a"]
  end

  # M14 stopgap: M17's [[keys.command]] parser replaces this test with its own
  test "[[keys.command]] plugin_action binds Plugins.Keybind; other types are diagnosed",
       %{tmp_dir: dir} do
    toml = """
    [[keys.command]]
    key = "prefix+g"
    type = "plugin_action"
    command = "demo.hello"

    [[keys.command]]
    key = "alt+g"
    type = "plugin_action"
    command = "demo.other"

    [[keys.command]]
    key = ["alt+h"]
    type = "plugin_action"
    command = "demo.hello"

    [[keys.command]]
    key = "prefix+t"
    type = "popup"
    command = "lazygit"

    [[keys.command]]
    key = "prefix+u"
    command = "make"
    """

    {kb, _ui, diags} = apply_cfg(load(dir, toml))
    assert Keybinds.lookup(kb, :prefix, {"g", []}) == Keybind.mfa("demo.hello")
    assert Keybinds.lookup(kb, :terminal, {"g", [:alt]}) == Keybind.mfa("demo.other")
    assert Keybinds.lookup(kb, :prefix, {"t", []}) == Keybinds.default().prefix_binds[{"t", []}]
    # one command, two entries: both keys stay bound
    assert Keybinds.lookup(kb, :terminal, {"h", [:alt]}) == Keybind.mfa("demo.hello")

    assert diags == [
             "config: keys.command type popup is not supported yet",
             "config: keys.command type shell is not supported yet"
           ]
  end

  test "bad TOML is the defaults and one diagnostic", %{tmp_dir: dir} do
    cfg = load(dir, "[keys\nnew_tab = ")
    assert cfg.onboarding == false
    assert cfg.failed
    refute Config.load(Path.join(dir, "missing.toml")).failed
    assert [<<"config: ", _::binary>>] = cfg.diagnostics
    {kb, _ui, [_]} = apply_cfg(cfg)
    assert kb == Keybinds.default()
  end

  test "unknown actions and bad key specs keep their defaults, one diagnostic each",
       %{tmp_dir: dir} do
    toml = """
    [keys]
    frobnicate = "prefix+f"
    new_tab = "hyper+q"
    prefix = "prefix+a"
    next_tab = 3
    rename_tab = "prefix+y"
    """

    {kb, _ui, diags} = apply_cfg(load(dir, toml))
    assert length(diags) == 4
    assert Enum.all?(diags, &String.starts_with?(&1, "config: keys."))
    assert Keybinds.lookup(kb, :prefix, {"c", []}) == {Prompt, :new_tab, []}
    assert Keybinds.lookup(kb, :prefix, {"n", []}) == {Actions, :next_tab, []}
    assert Keybinds.lookup(kb, :prefix, {"y", []}) == {Prompt, :rename_tab, []}
    assert kb.prefix == [{"b", [:ctrl]}]
  end

  test "[ui], [ui.sound], [ui.toast] and [theme] values", %{tmp_dir: dir} do
    toml = """
    [ui]
    sidebar_width = 30
    sidebar_min_width = 10
    sidebar_max_width = 50
    sidebar_start_collapsed = true
    confirm_close = false
    status_indicators = "symbols"
    prompt_new_tab_name = false
    pane_borders = "off"

    [ui.sound]
    enabled = false
    command = "say"

    [ui.toast]
    delivery = "terminal"
    delay_seconds = 3

    [theme]
    name = "nord"
    auto_switch = true
    light_name = "one-light"
    dark_name = "dracula"
    """

    cfg = load(dir, toml)
    {_kb, ui, []} = apply_cfg(cfg)
    assert %{width: 30, min: 10, max: 50, collapsed: false} = ui.sidebar
    assert ui.confirm_close == false
    assert ui.indicators == :symbols
    assert ui.prompt_new_tab_name == false
    assert ui.pane_borders == :off
    assert ui.sound == %{enabled: false, command: "say"}
    assert ui.toast == %{delivery: :terminal, delay_ms: 3000}
    assert ui.theme == %{name: "nord", auto_switch: true, light: "one-light", dark: "dracula"}

    {_kb, ui, []} = apply_cfg(cfg, start: true)
    assert ui.sidebar.collapsed
  end

  test "invalid values keep the current value with a diagnostic; unset keys keep theirs",
       %{tmp_dir: dir} do
    toml = """
    [ui]
    sidebar_width = 0
    status_indicators = "stars"
    sidebar_min_width = 40
    sidebar_max_width = 20
    [ui.toast]
    delay_seconds = 99999
    """

    current = put_in(ui().confirm_close, false)
    {_kb, ui, diags} = Config.apply(load(dir, toml), Keybinds.default(), current)
    assert length(diags) == 4
    assert ui.sidebar == current.sidebar
    assert ui.indicators == :dots
    assert ui.toast == current.toast
    assert ui.confirm_close == false
  end

  test "config_loaded swaps keybinds to defaults + config and applies the ui", %{tmp_dir: dir} do
    {app, _} = Actions.init(%{cols: 80, rows: 24})
    {:ok, kb} = Keybinds.rebind(app.ui.keybinds, "detach", "prefix+y")
    app = put_in(app.ui.keybinds, kb)

    cfg =
      load(dir, "onboarding = false\n[keys]\nnew_tab = \"prefix+t\"\n[ui]\nsidebar_width = 30\n")

    {app2, [{:config_diagnostics, []}]} = Actions.apply(app, {:config_loaded, cfg})
    assert Keybinds.lookup(app2.ui.keybinds, :prefix, {"t", []}) == {Prompt, :new_tab, []}
    assert Keybinds.lookup(app2.ui.keybinds, :prefix, {"q", []}) == {Actions, :detach, []}
    assert app2.ui.sidebar.width == 30
    assert app2.session.area != app.session.area
    assert app2.focus.modal == []
  end

  test "config_loaded opens onboarding only without an open modal", %{tmp_dir: dir} do
    {app, _} = Actions.init(%{cols: 80, rows: 24})
    cfg = Config.load(Path.join(dir, "missing.toml"))
    {app2, _} = Actions.apply(app, {:config_loaded, cfg})
    assert [%{kind: :onboarding}] = app2.focus.modal
    {app3, _} = Actions.apply(app2, {:config_loaded, cfg})
    assert [%{kind: :onboarding}] = app3.focus.modal
  end

  test "init/2 applies the config before the first spawn", %{tmp_dir: dir} do
    cfg = load(dir, "[ui]\nsidebar_start_collapsed = true\n")
    {app, [{:spawn, 1, _}, {:config_diagnostics, []}]} = Actions.init(%{cols: 80, rows: 24}, cfg)
    assert app.ui.sidebar.collapsed
    assert [%{kind: :onboarding}] = app.focus.modal
  end

  test "reload_config is prefix+shift+r and a catalog action" do
    kb = Keybinds.default()
    assert Keybinds.lookup(kb, :prefix, {"R", []}) == {Actions, :reload_config, []}
    assert Keybinds.to_config(kb)["reload_config"] == ["prefix+shift+r"]

    {_app, [{:reload_config}]} =
      Actions.reload_config(elem(Actions.init(%{cols: 80, rows: 24}), 0))
  end

  test "a failed load leaves a running app as it is and only reports", %{tmp_dir: dir} do
    {app, _} = Actions.init(%{cols: 80, rows: 24})
    {:ok, kb} = Keybinds.rebind(app.ui.keybinds, "prefix", "ctrl+a")
    app = put_in(app.ui.keybinds, kb)
    cfg = load(dir, "[keys\nprefix = ")

    assert {^app, [{:config_diagnostics, [<<"config: ", _::binary>>]}]} =
             Actions.apply(app, {:config_loaded, cfg})
  end
end
