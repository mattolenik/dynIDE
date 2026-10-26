defmodule DynideServer.App.CustomCommandsTest do
  # the Store test reads :config_path; the app env is global
  use ExUnit.Case, async: false
  @moduletag :capture_log
  @moduletag :tmp_dir

  alias DynideScene.Event
  alias DynideScene.Scene.Node
  alias DynideServer.Api.{Ids, SocketPath}
  alias DynideServer.App.{Actions, CustomCommands, Keybinds, Modal, Store, Ui}
  alias DynideServer.App.Modal.Keybinds, as: KeybindsModal
  alias DynideServer.Config
  alias DynideServer.Kernel.Fake.{Keeper, Pty}
  alias DynideServer.Pane.Rows

  @size %{cols: 120, rows: 40}

  defp load(dir, toml) do
    path = Path.join(dir, "config.toml")
    File.write!(path, toml)
    Config.load(path)
  end

  defp apply_cfg(cfg),
    do: Config.apply(cfg, Keybinds.default(), %Ui{keybinds: Keybinds.default()})

  defp app_with(dir, toml) do
    {kb, ui, diags} = apply_cfg(load(dir, toml))
    app = elem(Actions.init(@size), 0)
    {%{app | ui: %{ui | keybinds: kb}}, diags}
  end

  test "keys.command parses, binds and reports bad entries", %{tmp_dir: dir} do
    toml = """
    [keys]
    prefix = "ctrl+a"

    [[keys.command]]
    key = "prefix+o"
    command = "lazygit"
    type = "pane"
    description = "git"

    [[keys.command]]
    key = "alt+e"
    command = "echo hi"
    width = 40

    [[keys.command]]
    key = "prefix+y"
    command = "  "

    [[keys.command]]
    key = "prefix+u"
    command = "x"
    type = "nope"

    [[keys.command]]
    key = "ctrl+a"
    command = "x"

    [[keys.command]]
    key = "prefix+ctrl+a"
    command = "x"

    [[keys.command]]
    key = "prefix+q"
    command = "x"
    type = "popup"
    width = "50%"

    [[keys.command]]
    key = "prefix+o"
    command = "again"
    """

    {kb, ui, diags} = apply_cfg(load(dir, toml))

    assert [
             %{key: "prefix+o", command: "lazygit", type: "pane", description: "git"},
             %{key: "alt+e", type: "shell", description: nil, width: nil},
             %{key: "prefix+q", type: "popup", width: "50%", height: nil}
           ] = ui.custom_commands

    assert Keybinds.lookup(kb, :prefix, {"o", []}) == {CustomCommands, :run, [0]}
    assert Keybinds.lookup(kb, :terminal, {"e", [:alt]}) == {CustomCommands, :run, [1]}
    assert Keybinds.lookup(kb, :prefix, {"q", []}) == {CustomCommands, :run, [2]}

    assert diags == [
             "config: keys.command[1]: width and height apply only to popup commands; ignored",
             "config: keys.command[2]: empty command",
             "config: keys.command[3]: unknown type \"nope\"",
             "config: keys.command[4].key: ctrl+a is the prefix",
             "config: keys.command[5].key: prefix+ctrl+a is the prefix",
             "config: keys.command[6].key: prefix+q replaces keys.detach",
             "config: keys.command[7].key: prefix+o is another command's key"
           ]

    # a file without commands clears them
    {_kb, ui, []} = Config.apply(load(dir, ""), kb, ui)
    assert ui.custom_commands == []
  end

  test "the keybinds help lists custom commands under custom", %{tmp_dir: dir} do
    toml = """
    [[keys.command]]
    key = "prefix+o"
    command = "lazygit"
    description = "git ui"

    [[keys.command]]
    key = "prefix+e"
    command = "echo"
    """

    {app, []} = app_with(dir, toml)
    {app, []} = KeybindsModal.open(app)
    {app, _} = Actions.apply(app, DynideScene.Event.key("/"))

    app =
      Enum.reduce(String.graphemes("command["), app, fn c, app ->
        elem(Actions.apply(app, DynideScene.Event.key(c)), 0)
      end)

    list = Node.find(Modal.view(app, app.session.size), [:list]).children
    assert [%{role: :text, text: "custom"} | items] = list
    assert [%{text: "git ui", children: [g]}, %{text: "custom command"}] = items
    assert g.text == "prefix+o"
  end

  test "shell: the effect carries the command env", %{tmp_dir: dir} do
    {app, []} = app_with(dir, "[[keys.command]]\nkey = \"prefix+o\"\ncommand = \"echo hi\"\n")
    assert {^app, [{:custom_command, "echo hi", env, 1}]} = CustomCommands.run(app, 0)
    env = Map.new(env)
    assert env["HERDR_ACTIVE_WORKSPACE_ID"] == "w1"
    assert env["HERDR_ACTIVE_TAB_ID"] == Ids.tab(1, 1)
    assert env["HERDR_ACTIVE_PANE_ID"] == "p1"
    assert env["DYNIDE_API"] == SocketPath.path()
    refute Map.has_key?(env, "HERDR_ACTIVE_PANE_CWD")
  end

  test "pane, plugin_action and popup", %{tmp_dir: dir} do
    toml = """
    [[keys.command]]
    key = "prefix+o"
    command = "lazygit"
    type = "pane"

    [[keys.command]]
    key = "prefix+y"
    command = "demo.act"
    type = "plugin_action"

    [[keys.command]]
    key = "prefix+u"
    command = "x"
    type = "popup"
    """

    {app, []} = app_with(dir, toml)

    {app2, [{:spawn, 2, _size, opts}]} = CustomCommands.run(app, 0)
    assert %{cmd: "/bin/sh", args: ["-c", "lazygit"], env: [_ | _]} = opts
    assert app2.focus.pane == 2

    assert CustomCommands.run(app, 1) ==
             {app, [{:plugin, {:invoke, "demo.act", %{source: "keybinding"}}}]}

    {app3, [{:spawn, 2, %{cols: c, rows: r}, opts}]} = CustomCommands.run(app, 2)
    assert %{cmd: "/bin/sh", args: ["-c", "x"], identity: false} = opts
    assert %{kind: :popup, pane: 2, title: "popup"} = Modal.top(app3)
    assert app3.focus.pane == 1 and app3.session.next_id == 3 and c > 0 and r > 0
    # one popup at a time: the binding does not run under a modal, the command refuses
    assert {^app3, [{:notice, %{level: :warning, text: "popup: popup already open"}}]} =
             CustomCommands.run(app3, 2)

    assert {^app, [{:notice, _}]} = CustomCommands.run(app, 9)
  end

  test "the Store runs a shell command in the focused pane's cwd", %{tmp_dir: dir} do
    saved = Application.get_env(:dynide_server, :config_path)
    path = Path.join(dir, "config.toml")
    Application.put_env(:dynide_server, :config_path, path)

    on_exit(fn ->
      Application.put_env(:dynide_server, :config_path, saved)
      Store.reset()
    end)

    File.write!(path, """
    onboarding = false
    [[keys.command]]
    key = "prefix+o"
    command = "touch \\"$HERDR_ACTIVE_PANE_CWD/ran\\""
    """)

    Store.reset()
    :ok = Store.event({:resize, @size}, @size)
    pane = Store.snapshot().focus.pane
    {:ok, %{pty: pty}} = Keeper.lookup(Rows.kernel_id(pane))
    work = Path.join(dir, "work")
    File.mkdir_p!(work)
    :ok = Pty.set_cwd(pty, work)

    :ok = Store.run({CustomCommands, :run, [0]}, @size)
    ran = Path.join(work, "ran")
    assert Enum.any?(1..250, fn _ -> File.exists?(ran) or (Process.sleep(20) && false) end)
  end

  test "the Store opens a popup: keys reach its pane, its exit pops the modal", %{tmp_dir: dir} do
    saved = Application.get_env(:dynide_server, :config_path)
    path = Path.join(dir, "config.toml")
    Application.put_env(:dynide_server, :config_path, path)

    on_exit(fn ->
      Application.put_env(:dynide_server, :config_path, saved)
      Store.reset()
    end)

    File.write!(path, """
    onboarding = false
    [[keys.command]]
    key = "prefix+o"
    command = "lazygit"
    type = "popup"
    width = "50%"
    """)

    Store.reset()
    :ok = Store.event({:resize, @size}, @size)
    :ok = Store.run({CustomCommands, :run, [0]}, @size)
    %{kind: :popup, pane: id} = Modal.top(Store.snapshot())
    {:ok, %{pty: pty}} = Keeper.lookup(Rows.kernel_id(id))

    # no pane identity, not even one the VM inherited (nil: the kernel removes it)
    env = Map.new(Keeper.last_spec().env)

    for k <- ~w(HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID DYNIDE_BROKER_SOCK DYNIDE_GEN),
        do: assert(Map.fetch(env, k) == {:ok, nil}, k)

    :ok = Store.event(Event.key("q"), @size)
    assert Enum.any?(1..100, fn _ -> Pty.writes(pty) != [] or (Process.sleep(10) && false) end)

    Pty.kill(pty, :term)

    assert Enum.any?(1..100, fn _ ->
             Store.snapshot().focus.modal == [] or (Process.sleep(10) && false)
           end)
  end

  test "exec logs only a bounded, valid UTF-8 excerpt of a failing command's output" do
    # 199 ASCII bytes, then a 2-byte é cut at byte 200, then far more output
    cmd = "printf '%0199d' 0; printf 'é'; head -c 100000 /dev/zero | tr '\\0' y; exit 3"

    log = ExUnit.CaptureLog.capture_log(fn -> assert CustomCommands.exec(cmd, [], nil) == :ok end)
    [_, excerpt] = String.split(log, "custom command exited 3: #{inspect(cmd)}: ")
    excerpt = String.trim_trailing(excerpt)
    assert excerpt == String.duplicate("0", 199)
  end
end
