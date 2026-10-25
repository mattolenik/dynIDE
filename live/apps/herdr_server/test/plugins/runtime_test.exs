defmodule HerdrServer.Plugins.RuntimeTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrServer.Api.Events
  alias HerdrServer.Api.Handlers.Plugins, as: Handler
  alias HerdrServer.App.{Commands, Store}
  alias HerdrServer.Plugins.{Install, Menu, Paths, Runtime}
  alias HerdrServer.Test.PluginDirs

  setup do
    base = PluginDirs.use_tmp()
    Store.reset()
    on_exit(&Store.reset/0)
    on_exit(fn -> Menu.put([]) end)
    %{base: base}
  end

  defp start_runtime do
    start_supervised!({Task.Supervisor, name: HerdrServer.Plugins.Tasks})
    start_supervised!(Runtime)
  end

  defp link(base, id, toml, enabled \\ true) do
    dir = PluginDirs.plugin(Path.join(base, id), id, toml)
    {:ok, _} = Install.link(dir, enabled)
    dir
  end

  defp action(cmd), do: "[[actions]]\nid = \"go\"\ntitle = \"Go\"\ncommand = #{cmd}\n"

  defp finished(log_id, tries \\ 100) do
    case Enum.find(Runtime.logs(nil, 200), &(&1["log_id"] == log_id)) do
      %{"status" => s} = log when s != "running" -> log
      _ when tries > 0 -> Process.sleep(50) && finished(log_id, tries - 1)
      other -> flunk("not finished: #{inspect(other)}")
    end
  end

  defp wait_file(path, tries \\ 100) do
    cond do
      File.exists?(path) and File.read!(path) != "" -> File.read!(path)
      tries > 0 -> Process.sleep(50) && wait_file(path, tries - 1)
      true -> flunk("#{path} never written")
    end
  end

  test "an action runs in the plugin root with the herdr env and logs its output", %{base: base} do
    cmd =
      ~S(["sh", "-c", "printf '%s|%s|%s' \"$HERDR_PLUGIN_ID\" \"$HERDR_PLUGIN_ACTION_ID\" \"$PWD\""])

    dir = link(base, "t.p", action(cmd))
    start_runtime()

    assert {:ok, %{action: a, context: ctx, log: %{"log_id" => "plugin-log-1" = id} = log}} =
             Runtime.invoke("t.p.go", nil, %{}, "api")

    assert a["plugin_id"] == "t.p" and a["action_id"] == "go"
    assert ctx["invocation_source"] == "api"
    assert log["status"] == "running"
    {real, 0} = System.cmd("pwd", ["-P"], cd: dir)

    assert %{"status" => "succeeded", "exit_code" => 0, "stdout" => out} = log = finished(id)
    refute Map.has_key?(log, "event")

    assert out == "t.p|go|" <> String.trim(real)
    assert [%{"log_id" => ^id}] = Runtime.logs("t.p", 10)
    assert Runtime.logs("t.other", 10) == []
  end

  test "a local id in two plugins is ambiguous; a disabled plugin fails", %{base: base} do
    link(base, "a.one", action(~s(["true"])))
    link(base, "b.two", action(~s(["true"])))

    link(
      base,
      "c.off",
      "[[actions]]\nid = \"stop\"\ntitle = \"S\"\ncommand = [\"true\"]\n",
      false
    )

    start_runtime()

    assert {:error, "ambiguous_plugin_action", _} = Runtime.invoke("go", nil, %{}, "api")

    assert {:error, :invalid_params, _, %{reason: "ambiguous_plugin_action"}} =
             Handler.handle("plugin.action.invoke", %{action_id: "go"})

    assert {:ok, %{type: "plugin_action_invoked"}} =
             Handler.handle("plugin.action.invoke", %{action_id: "go", plugin_id: "b.two"})

    assert {:error, :failed, _, %{reason: "plugin_disabled"}} =
             Handler.handle("plugin.action.invoke", %{action_id: "c.off.stop"})

    assert {:error, :not_found, _, %{reason: "plugin_action_not_found"}} =
             Handler.handle("plugin.action.invoke", %{action_id: "nope"})

    assert {:ok, %{actions: actions}} = Handler.handle("plugin.action.list", %{})

    assert Enum.map(actions, &"#{&1["plugin_id"]}.#{&1["action_id"]}") ==
             ~w(a.one.go b.two.go c.off.stop)

    assert {:ok, %{actions: [_]}} = Handler.handle("plugin.action.list", %{plugin_id: "a.one"})
    assert {:ok, %{logs: [_]}} = Handler.handle("plugin.log.list", %{plugin_id: "b.two"})
  end

  test "the 33rd command in flight is refused and logged", %{base: base} do
    link(base, "t.p", action(~s(["sleep", "5"])))
    start_runtime()

    for _ <- 1..32, do: assert({:ok, _} = Runtime.invoke("go", nil, %{}, "api"))

    assert {:error, "plugin_command_limit_reached", msg} = Runtime.invoke("go", nil, %{}, "api")
    assert msg =~ "32"
    assert %{"status" => "failed", "error" => ^msg} = List.last(Runtime.logs(nil, 200))
    # still responsive
    assert length(Runtime.logs(nil, 200)) == 33
  end

  test "a startup hook runs once when the runtime starts", %{base: base} do
    link(base, "t.p", """
    [[startup]]
    command = ["sh", "-c", "printf '%s %s' \\"$HERDR_PLUGIN_EVENT\\" \\"$HERDR_PLUGIN_ID\\" > \\"$HERDR_PLUGIN_STATE_DIR/started\\""]
    """)

    start_runtime()
    assert wait_file(Path.join(Paths.plugin_state_dir("t.p"), "started")) == "startup t.p"
    assert [%{"event" => "startup"}] = Runtime.logs(nil, 10)
  end

  test "an event hook on tab.created runs after a tab is created", %{base: base} do
    link(base, "t.p", """
    [[events]]
    on = "tab.created"
    command = ["sh", "-c", "printf '%s' \\"$HERDR_PLUGIN_EVENT_JSON\\" > \\"$HERDR_PLUGIN_STATE_DIR/event\\""]
    """)

    {:ok, _, _} = Store.request({Commands, :noop, []})
    start_supervised!(Events)
    start_runtime()
    # the runtime subscribes in handle_continue: a round trip waits for it
    _ = :sys.get_state(Runtime)
    {:ok, _, _} = Store.request({Commands, :create_tab, [1, "x", true]})

    ev = JSON.decode!(wait_file(Path.join(Paths.plugin_state_dir("t.p"), "event")))
    assert ev["event"] == "tab.created"
  end

  test "the manifest is re-read on each invoke", %{base: base} do
    dir = link(base, "t.p", action(~s(["printf", "one"])))
    start_runtime()
    {:ok, %{log: %{"log_id" => id1}}} = Runtime.invoke("go", nil, %{}, "api")
    assert finished(id1)["stdout"] == "one"

    PluginDirs.plugin(dir, "t.p", action(~s(["printf", "two"])))
    {:ok, %{log: %{"log_id" => id2}}} = Runtime.invoke("go", nil, %{}, "api")
    assert finished(id2)["stdout"] == "two"
  end

  test "a keybind invocation that fails toasts", %{base: base} do
    link(base, "t.p", action(~s(["true"])))
    {:ok, _, _} = Store.request({Commands, :noop, []})
    start_runtime()
    Store.subscribe(self())
    send(Runtime, {{:invoke, "nope", %{source: "keybinding"}}, self()})
    assert_receive {:alert, %{kind: :notification, body: body}}, 2000
    assert body =~ "not found"
  end
end
