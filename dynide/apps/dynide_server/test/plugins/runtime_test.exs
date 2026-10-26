defmodule DynideServer.Plugins.RuntimeTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias DynideServer.Api.Events
  alias DynideServer.Api.Handlers.Plugins, as: Handler
  alias DynideServer.App.{Commands, Store}
  alias DynideServer.Plugins.{Install, Menu, Paths, Runtime}
  alias DynideServer.Test.PluginDirs

  setup do
    base = PluginDirs.use_tmp()
    Store.reset()
    on_exit(&Store.reset/0)
    on_exit(fn -> Menu.put([]) end)
    # startup hooks run once per VM; each test is a fresh "VM" here
    :persistent_term.erase({Runtime, :startup_ran})
    %{base: base}
  end

  defp start_runtime do
    start_supervised!({Task.Supervisor, name: DynideServer.Plugins.Tasks})
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

  defp wait_restart(old, tries \\ 100) do
    case Process.whereis(Runtime) do
      pid when is_pid(pid) and pid != old -> pid
      _ when tries > 0 -> Process.sleep(20) && wait_restart(old, tries - 1)
      _ -> flunk("runtime never restarted")
    end
  end

  defp read_pids(path) do
    case File.read(path) do
      {:ok, text} -> String.split(text)
      {:error, _} -> []
    end
  end

  defp kill_pids(path) do
    case read_pids(path) do
      [] -> :ok
      pids -> System.cmd("kill", ["-9" | pids], stderr_to_stdout: true)
    end
  end

  defp wait_lines(path, n, tries \\ 200) do
    cond do
      length(read_pids(path)) >= n -> :ok
      tries > 0 -> Process.sleep(50) && wait_lines(path, n, tries - 1)
      true -> flunk("#{path}: #{length(read_pids(path))} of #{n} pids written")
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

    assert {:ok, %{type: "plugin_action_invoked", log: %{"log_id" => run}}} =
             Handler.handle("plugin.action.invoke", %{action_id: "go", plugin_id: "b.two"})

    # ends before the tmp dir goes (a run left in flight starts in a removed cwd)
    finished(run)

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
    pids = Path.join(base, "pids")
    sleeper = ~s(["sh", "-c", "echo $$ >> #{pids}; exec sleep 5"])
    link(base, "t.p", action(sleeper))
    # kill exactly the sleeps this test started, also when an assertion fails, before
    # PluginDirs removes the tmp dir (on_exit runs in reverse order)
    on_exit(fn -> kill_pids(pids) end)
    start_runtime()

    for _ <- 1..32, do: assert({:ok, _} = Runtime.invoke("go", nil, %{}, "api"))
    wait_lines(pids, 32)

    assert {:error, "plugin_command_limit_reached", msg} = Runtime.invoke("go", nil, %{}, "api")
    assert msg =~ "32"
    assert %{"status" => "failed", "error" => ^msg} = List.last(Runtime.logs(nil, 200))
    # still responsive
    assert length(Runtime.logs(nil, 200)) == 33

    # let their runs finish
    kill_pids(pids)
    for %{"log_id" => id} <- Runtime.logs(nil, 200), do: finished(id, 200)
  end

  test "a startup hook runs once when the runtime starts", %{base: base} do
    link(base, "t.p", """
    [[startup]]
    command = ["sh", "-c", "printf '%s %s' \\"$HERDR_PLUGIN_EVENT\\" \\"$HERDR_PLUGIN_ID\\" > \\"$HERDR_PLUGIN_STATE_DIR/started\\""]
    """)

    start_runtime()
    started = Path.join(Paths.plugin_state_dir("t.p"), "started")
    assert wait_file(started) == "startup t.p"
    assert [%{"event" => "startup"}] = Runtime.logs(nil, 10)

    # a crashed Runtime restarts in the same VM without running them again
    File.rm!(started)
    old = Process.whereis(Runtime)
    Process.exit(old, :kill)
    new = wait_restart(old)
    _ = :sys.get_state(new)
    assert Runtime.logs(nil, 10) == []
    refute File.exists?(started)
  end

  test "removing the last hook unsubscribes from the hub", %{base: base} do
    link(base, "t.p", """
    [[events]]
    on = "tab.created"
    command = ["true"]
    """)

    start_supervised!(Events)
    start_runtime()
    rt = Process.whereis(Runtime)
    _ = :sys.get_state(rt)
    assert Map.has_key?(:sys.get_state(Events).subs, rt)

    {:ok, _} = Install.set_enabled("t.p", false)
    _ = :sys.get_state(rt)
    assert %{subs: subs, store?: false, last: nil} = :sys.get_state(Events)
    assert subs == %{}
  end

  test "a failing invoke answers failed and keeps the runtime", %{base: base} do
    link(base, "t.p", action(~s(["true"])))
    start_runtime()
    rt = Process.whereis(Runtime)
    # an override that cannot be encoded as context JSON raises inside the invoke
    assert {:error, "plugin_runtime_failed", _} =
             Runtime.invoke("go", nil, %{"clicked_url" => {:not, :json}}, "api")

    assert Process.whereis(Runtime) == rt
    assert {:ok, _} = Runtime.invoke("go", nil, %{}, "api")
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

  test "an event hook on pane.agent_status_changed runs with the agent in its context",
       %{base: base} do
    link(base, "t.p", """
    [[events]]
    on = "pane.agent_status_changed"
    command = ["sh", "-c", "printf '%s\\n%s' \\"$HERDR_PLUGIN_EVENT_JSON\\" \\"$HERDR_PLUGIN_CONTEXT_JSON\\" > \\"$HERDR_PLUGIN_STATE_DIR/event\\""]
    """)

    {:ok, _, _} = Store.request({Commands, :noop, []})
    start_supervised!(Events)
    start_runtime()
    _ = :sys.get_state(Runtime)
    # the detection poller's events
    Store.event_async({:pane_agent, 1, "claude"})
    Store.event_async({:agent_state, 1, :working})

    [ev, ctx] = String.split(wait_file(Path.join(Paths.plugin_state_dir("t.p"), "event")), "\n")

    assert %{"event" => "pane.agent_status_changed", "agent_status" => "working"} =
             JSON.decode!(ev)

    assert %{"focused_pane_agent" => "claude", "focused_pane_agent_status" => "working"} =
             JSON.decode!(ctx)
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
