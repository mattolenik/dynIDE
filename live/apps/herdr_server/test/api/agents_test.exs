defmodule HerdrServer.Api.AgentsTest do
  # agent.* and the manifest and hook methods over the socket, the fake kernel and the
  # app's own Detect.Poller
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrServer.Api.{Listener, Spec}
  alias HerdrServer.App.Store
  alias HerdrServer.Detect.{Manifests, Poller}
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Pane.{Facts, Rows}
  alias HerdrServer.Test.ApiClient

  @moduletag :tmp_dir

  setup do
    fresh()
    on_exit(&fresh/0)
    sock = Path.join(System.tmp_dir!(), "hla#{System.unique_integer([:positive])}")
    File.mkdir_p!(sock)
    on_exit(fn -> File.rm_rf!(sock) end)
    path = Path.join(sock, "a.sock")
    start_supervised!({Listener, [path: path, reload_server: :no_reload_server]})
    s = ApiClient.connect(path)
    ApiClient.call(s, "workspace.list")
    {:ok, %{pty: pty}} = Fake.Keeper.lookup(Rows.kernel_id(1))
    # the poller sees panes through the Mirror (a 20 ms debounce behind the Store)
    mirrored!(1)
    %{s: s, pty: pty, path: path}
  end

  # a restarted poller holds no tracker (agent, hook) left by another test's pane 1
  defp fresh do
    :ok = Supervisor.terminate_child(HerdrServer.Supervisor, Poller)
    Store.reset()
    Enum.each(Facts.agent_ids(), &Facts.delete_agent/1)
    {:ok, _} = Supervisor.restart_child(HerdrServer.Supervisor, Poller)
  end

  defp ok!(s, method, params \\ %{}) do
    reply = ApiClient.call(s, method, params)
    assert %{"result" => r} = reply, "#{method}: #{inspect(reply)}"
    assert Spec.validate_result(method, r) == :ok, inspect(r)
    r
  end

  defp err(s, method, params) do
    assert %{"error" => e} = ApiClient.call(s, method, params)
    {e["code"], e["message"]}
  end

  defp event!(ev) do
    Store.event_async(ev)
    # a sync request behind the cast: the event is applied when it answers
    Store.snapshot()
    :sys.get_state(Store)
  end

  defp mirrored!(id) do
    Enum.find(1..100, fn _ ->
      Map.has_key?((HerdrServer.Mirror.app() || %{session: %{panes: %{}}}).session.panes, id) ||
        (Process.sleep(10) && false)
    end) || flunk("pane #{id} never mirrored")
  end

  defp split!(s), do: ok!(s, "pane.split", %{"direction" => "right"})

  test "list is empty, then holds the detected agent", %{s: s} do
    assert ok!(s, "agent.list")["agents"] == []
    event!({:pane_agent, 1, "claude"})

    assert [%{"pane_id" => "p1", "agent" => "claude", "agent_status" => "unknown"}] =
             ok!(s, "agent.list")["agents"]
  end

  test "get by pane id and by label; an ambiguous label lists the panes", %{s: s} do
    split!(s)
    event!({:pane_agent, 2, "claude"})
    assert %{"pane_id" => "p2"} = ok!(s, "agent.get", %{"target" => "claude"})["agent"]

    assert %{"pane_id" => "p1", "agent" => nil} =
             ok!(s, "agent.get", %{"target" => "p1"})["agent"]

    event!({:pane_agent, 1, "claude"})
    assert {"not_found", msg} = err(s, "agent.get", %{"target" => "claude"})
    assert msg =~ "p1, p2"
    assert {"not_found", _} = err(s, "agent.get", %{"target" => "codex"})
  end

  test "read, prompt and send_keys act on the target's pane", %{s: s, pty: pty} do
    event!({:pane_agent, 1, "claude"})
    Fake.Pty.output(pty, "hello agent")

    Enum.find(1..50, fn _ ->
      ok!(s, "agent.read", %{"target" => "claude"})["text"] == "hello agent" ||
        (Process.sleep(20) && false)
    end) || flunk("never read the output")

    ok!(s, "agent.send_keys", %{"target" => "claude", "keys" => ["a"]})
    ok!(s, "agent.prompt", %{"target" => "p1", "text" => "fix it"})

    Enum.find(1..50, fn _ ->
      pty |> Fake.Pty.writes() |> IO.iodata_to_binary() =~ ~r/^a.*fix it.*\r$/s ||
        (Process.sleep(20) && false)
    end) || flunk("writes: #{inspect(Fake.Pty.writes(pty))}")
  end

  test "explain over text uses a reloaded override manifest", %{s: s, tmp_dir: dir} do
    saved = Application.get_env(:herdr_server, :config_path)
    Application.put_env(:herdr_server, :config_path, Path.join(dir, "config.toml"))

    on_exit(fn ->
      if saved,
        do: Application.put_env(:herdr_server, :config_path, saved),
        else: Application.delete_env(:herdr_server, :config_path)

      Manifests.reload()
    end)

    File.mkdir_p!(Path.join(dir, "agent-detection"))

    File.write!(Path.join(dir, "agent-detection/claude.toml"), """
    id = "claude"
    version = "9.9"
    [[rules]]
    id = "magic"
    state = "blocked"
    contains = ['MAGIC']
    """)

    manifests = ok!(s, "server.reload_agent_manifests")["manifests"]
    assert %{"source" => "override"} = Enum.find(manifests, &(&1["agent"] == "claude"))
    assert length(ok!(s, "server.agent_manifests")["manifests"]) >= 20

    r = ok!(s, "agent.explain", %{"agent" => "claude", "text" => "x\nMAGIC\n"})
    assert %{"state" => "blocked", "matched_rule" => %{"id" => "magic"}} = r["agent"]
    assert r["explanation"] =~ "rule: magic (region="
    refute r["explanation"] =~ "evaluated_rules:"

    v = ok!(s, "agent.explain", %{"agent" => "claude", "text" => "x", "verbose" => true})
    assert v["explanation"] =~ "evaluated_rules:"
    assert v["agent"]["fallback_reason"] == "default_known_agent_idle_fallback"
  end

  test "explain a pane without an agent fails; target and text together are invalid", %{s: s} do
    assert {"failed", "pane has no detected agent"} = err(s, "agent.explain", %{"target" => "p1"})
    assert {"not_found", _} = err(s, "agent.explain", %{"target" => "p9"})

    assert {"invalid_params", _} =
             err(s, "agent.explain", %{"target" => "p1", "agent" => "claude", "text" => "x"})

    assert {"invalid_params", _} = err(s, "agent.explain", %{})
  end

  test "wait answers when the status flips, and times out", %{s: s, path: path} do
    event!({:pane_agent, 1, "claude"})
    event!({:agent_state, 1, :working})

    assert {"timeout", _} =
             err(s, "agent.wait", %{"target" => "claude", "timeout_ms" => 50})

    s2 = ApiClient.connect(path)
    task = Task.async(fn -> ApiClient.call(s2, "agent.wait", %{"target" => "claude"}) end)
    Process.sleep(150)
    event!({:agent_state, 1, :idle})
    assert %{"result" => %{"agent" => %{"agent_status" => "idle"}}} = Task.await(task)

    assert %{"agent" => %{"agent_status" => "idle"}} =
             ok!(s, "agent.wait", %{"target" => "p1", "until" => ["idle", "done"]})
  end

  test "a full-lifecycle hook skips the screen; release drops it", %{s: s} do
    hook = %{"pane_id" => "p1", "source" => "herdr:pi", "agent" => "pi"}
    ok!(s, "pane.report_agent", Map.merge(hook, %{"state" => "working", "seq" => 1}))
    assert %{hook_source: "herdr:pi", skipped: true, state: :working} = Facts.agent(1)

    r = ok!(s, "agent.explain", %{"target" => "p1"})

    assert %{"screen_detection_skipped" => true, "state" => "working", "agent" => "pi"} =
             r["agent"]

    assert r["agent"]["matched_rule"] == nil

    ok!(s, "pane.release_agent", hook)
    assert %{hook_source: nil, skipped: false} = Facts.agent(1)

    assert {"not_found", _} =
             err(s, "pane.report_agent", %{hook | "pane_id" => "p9"} |> Map.put("state", "idle"))
  end

  test "another hook sets the hook source but explain still reads the screen", %{s: s, pty: pty} do
    Fake.Pty.output(pty, "\r\n Run a dynamic workflow?\r\n esc to cancel\r\n")
    hook = %{"pane_id" => "p1", "source" => "claude-hooks", "agent" => "claude"}
    ok!(s, "pane.report_agent", Map.merge(hook, %{"state" => "working", "seq" => 1}))
    assert %{hook_source: "claude-hooks", skipped: false} = Facts.agent(1)

    r =
      Enum.find_value(1..50, fn _ ->
        r = ok!(s, "agent.explain", %{"target" => "p1"})
        if r["agent"]["matched_rule"], do: r, else: Process.sleep(20) && nil
      end) || flunk("explain never matched the blocked dialog")

    assert %{"screen_detection_skipped" => false, "state" => "blocked"} = r["agent"]
    assert ok!(s, "agent.get", %{"target" => "p1"})["agent"]["hook_source"] == "claude-hooks"
  end
end
