defmodule HerdrCli.ArgvTest do
  use ExUnit.Case, async: true

  alias HerdrCli.Argv

  defp p(line, env \\ %{}), do: Argv.parse(OptionParser.split(line), env)

  describe "server and reload verbs" do
    test "ping, api schema, server status" do
      assert p("ping") == {:call, "ping", %{}, :json}
      assert p("api schema") == {:call, "api.schema", %{}, :json}
      assert p("server status") == {:call, "server.status", %{}, :json}
      assert p("server status --kv") == {:call, "server.status", %{}, :lines}
    end

    test "api call passes method and json params through" do
      assert p(~s(api call pane.get '{"pane_id":"p1"}')) ==
               {:call, "pane.get", %{"pane_id" => "p1"}, :json}

      assert p("api call ping") == {:call, "ping", %{}, :json}
      assert {:usage, _} = p("api call pane.get {nope")
      assert {:usage, _} = p("api call pane.get [1]")
      assert {:usage, _} = p("api call")
    end

    test "rollback" do
      assert p("rollback") == {:call, "reload.rollback", %{}, :rollback}
      assert p("rollback 3") == {:call, "reload.rollback", %{"n" => 3}, :rollback}
      # leading zeros parse as the number (the old stub crashed on them)
      assert p("rollback 007") == {:call, "reload.rollback", %{"n" => 7}, :rollback}
      assert {:usage, _} = p("rollback x")
      assert {:usage, _} = p("rollback 1.5")
      assert {:usage, _} = p("rollback 1 2")
    end

    test "test-on-save" do
      assert p("test-on-save") == {:call, "reload.test_on_save", %{}, :gate}
      assert p("test-on-save on") == {:call, "reload.test_on_save", %{"mode" => "on"}, :gate}
      assert p("test-on-save off") == {:call, "reload.test_on_save", %{"mode" => "off"}, :gate}
      assert {:usage, _} = p("test-on-save maybe")
    end
  end

  describe "workspace" do
    test "every verb" do
      assert p("workspace list") == {:call, "workspace.list", %{}, :json}
      assert p("workspace get w1") == {:call, "workspace.get", %{"workspace_id" => "w1"}, :json}

      assert p("workspace create") == {:call, "workspace.create", %{}, :json}

      assert p("workspace create --label api --focus") ==
               {:call, "workspace.create", %{"label" => "api", "focus" => true}, :json}

      assert p("workspace create --label=api") ==
               {:call, "workspace.create", %{"label" => "api"}, :json}

      assert p("workspace focus w2") ==
               {:call, "workspace.focus", %{"workspace_id" => "w2"}, :json}

      assert p("workspace rename w2 'my ws'") ==
               {:call, "workspace.rename", %{"workspace_id" => "w2", "label" => "my ws"}, :json}

      assert p("workspace close w2") ==
               {:call, "workspace.close", %{"workspace_id" => "w2"}, :json}
    end

    test "usage errors" do
      assert {:usage, _} = p("workspace")
      assert {:usage, _} = p("workspace get")
      assert {:usage, _} = p("workspace get w1 w2")
      assert {:usage, _} = p("workspace create --bogus")
      assert {:usage, _} = p("workspace create --label")
      assert {:usage, _} = p("workspace create --focus=yes")
      assert {:usage, _} = p("workspace explode")
    end
  end

  describe "tab" do
    test "every verb" do
      assert p("tab list") == {:call, "tab.list", %{}, :json}

      assert p("tab list --workspace w1") ==
               {:call, "tab.list", %{"workspace_id" => "w1"}, :json}

      assert p("tab get w1:t2") == {:call, "tab.get", %{"tab_id" => "w1:t2"}, :json}

      assert p("tab create --workspace w1 --label t --focus") ==
               {:call, "tab.create", %{"workspace_id" => "w1", "label" => "t", "focus" => true},
                :json}

      assert p("tab focus w1:t2") == {:call, "tab.focus", %{"tab_id" => "w1:t2"}, :json}

      assert p("tab rename w1:t2 logs") ==
               {:call, "tab.rename", %{"tab_id" => "w1:t2", "label" => "logs"}, :json}

      assert p("tab close w1:t2") == {:call, "tab.close", %{"tab_id" => "w1:t2"}, :json}
    end
  end

  describe "pane" do
    test "list, get, current" do
      assert p("pane list") == {:call, "pane.list", %{}, :json}

      assert p("pane list --workspace w1 --tab=w1:t1") ==
               {:call, "pane.list", %{"workspace_id" => "w1", "tab_id" => "w1:t1"}, :json}

      assert p("pane get p3") == {:call, "pane.get", %{"pane_id" => "p3"}, :json}
      assert p("pane current") == {:call, "pane.current", %{}, :json}

      assert p("pane current", %{"HERDR_PANE_ID" => "p4"}) ==
               {:call, "pane.current", %{"caller_pane_id" => "p4"}, :json}

      assert p("pane current", %{"HERDR_PANE_ID" => ""}) == {:call, "pane.current", %{}, :json}
    end

    test "split" do
      assert p("pane split --direction right") ==
               {:call, "pane.split", %{"direction" => "right"}, :json}

      assert p("pane split p2 --direction down --ratio 0.3 --focus") ==
               {:call, "pane.split",
                %{"pane_id" => "p2", "direction" => "down", "ratio" => 0.3, "focus" => true},
                :json}

      assert p("pane split --direction=down", %{"HERDR_PANE_ID" => "p4"}) ==
               {:call, "pane.split", %{"pane_id" => "p4", "direction" => "down"}, :json}

      assert p("pane split --ratio 1 --direction right") ==
               {:call, "pane.split", %{"direction" => "right", "ratio" => 1.0}, :json}

      assert {:usage, _} = p("pane split --direction left")
      assert {:usage, _} = p("pane split")
      assert {:usage, _} = p("pane split --direction right --ratio half")
    end

    test "close, focus, layout, process-info" do
      assert p("pane close p2") == {:call, "pane.close", %{"pane_id" => "p2"}, :json}
      assert p("pane focus p2") == {:call, "pane.focus", %{"pane_id" => "p2"}, :json}
      assert p("pane layout") == {:call, "pane.layout", %{}, :json}
      assert p("pane layout p2") == {:call, "pane.layout", %{"pane_id" => "p2"}, :json}

      assert p("pane layout", %{"HERDR_PANE_ID" => "p4"}) ==
               {:call, "pane.layout", %{"pane_id" => "p4"}, :json}

      assert p("pane process-info p2") ==
               {:call, "pane.process_info", %{"pane_id" => "p2"}, :json}

      assert p("pane process-info", %{"HERDR_PANE_ID" => "p4"}) ==
               {:call, "pane.process_info", %{"pane_id" => "p4"}, :json}

      assert {:usage, _} = p("pane process-info")
      assert {:usage, _} = p("pane close")
    end

    test "send-text, send-keys, run" do
      assert p("pane send-text p2 'echo hi'") ==
               {:call, "pane.send_text", %{"pane_id" => "p2", "text" => "echo hi"}, :json}

      # `--` ends options, so text may start with dashes
      assert p("pane send-text p2 -- --help") ==
               {:call, "pane.send_text", %{"pane_id" => "p2", "text" => "--help"}, :json}

      assert p("pane send-keys p2 C-c Enter") ==
               {:call, "pane.send_keys", %{"pane_id" => "p2", "keys" => ["C-c", "Enter"]}, :json}

      assert p("pane run p2 'make test'") ==
               {:call, "pane.run", %{"pane_id" => "p2", "command" => "make test"}, :json}

      assert {:usage, _} = p("pane send-keys p2")
      assert {:usage, _} = p("pane send-text p2")
      assert {:usage, _} = p("pane run p2 make test")
    end

    test "read" do
      assert p("pane read p2") == {:call, "pane.read", %{"pane_id" => "p2"}, :text}

      assert p("pane read p2 --source recent --lines 50") ==
               {:call, "pane.read", %{"pane_id" => "p2", "source" => "recent", "lines" => 50},
                :text}

      assert {:usage, _} = p("pane read")

      assert p("pane read", %{"HERDR_PANE_ID" => "p4"}) ==
               {:call, "pane.read", %{"pane_id" => "p4"}, :text}

      assert {:usage, _} = p("pane read p2 --source everything")
      assert {:usage, _} = p("pane read p2 --lines many")
    end

    test "wait-output" do
      assert p("pane wait-output p2 --match done --timeout 5000") ==
               {:call, "pane.wait_for_output",
                %{"pane_id" => "p2", "match" => "done", "timeout_ms" => 5000}, :json}

      assert p(
               "pane wait-output --regex '^ok$' --source recent --lines 10",
               %{"HERDR_PANE_ID" => "p4"}
             ) ==
               {:call, "pane.wait_for_output",
                %{"pane_id" => "p4", "regex" => "^ok$", "source" => "recent", "lines" => 10},
                :json}

      assert {:usage, _} = p("pane wait-output p2")
      assert {:usage, _} = p("pane wait-output p2 --match a --regex b")
    end
  end

  describe "agent" do
    test "every verb" do
      assert p("agent list") == {:call, "agent.list", %{}, :json}
      assert p("agent get p1") == {:call, "agent.get", %{"target" => "p1"}, :json}

      assert p("agent read claude --source recent --lines 5") ==
               {:call, "agent.read", %{"target" => "claude", "source" => "recent", "lines" => 5},
                :text}

      assert p("agent explain p1") == {:call, "agent.explain", %{"target" => "p1"}, :json}

      assert p("agent wait p1 --until idle --until done --timeout 100") ==
               {:call, "agent.wait",
                %{"target" => "p1", "until" => ["idle", "done"], "timeout_ms" => 100}, :json}

      assert p("agent prompt p1 'fix it'") ==
               {:call, "agent.prompt", %{"target" => "p1", "text" => "fix it"}, :json}

      assert p("agent send-keys p1 Escape") ==
               {:call, "agent.send_keys", %{"target" => "p1", "keys" => ["Escape"]}, :json}

      assert {:usage, _} = p("agent wait p1 --until sleeping")
    end
  end

  describe "events" do
    test "subscribe builds one subscription per type with the shared filters" do
      assert p("events subscribe pane.created") ==
               {:subscribe, %{"subscriptions" => [%{"type" => "pane.created"}]}}

      assert p("events subscribe pane.created pane.closed --pane p2 --workspace w1") ==
               {:subscribe,
                %{
                  "subscriptions" => [
                    %{"type" => "pane.created", "pane_id" => "p2", "workspace_id" => "w1"},
                    %{"type" => "pane.closed", "pane_id" => "p2", "workspace_id" => "w1"}
                  ]
                }}

      assert p("events subscribe tab.focused --tab w1:t1") ==
               {:subscribe,
                %{"subscriptions" => [%{"type" => "tab.focused", "tab_id" => "w1:t1"}]}}

      assert {:usage, _} = p("events subscribe")
      assert {:usage, _} = p("events")
    end
  end

  test "no verb, help and unknown verbs are usage" do
    assert {:usage, text} = p("")
    assert text =~ "usage: herdr-live"
    assert {:usage, _} = p("help")
    assert {:usage, _} = p("frobnicate")
  end

  test "verbs/0 lists every top-level verb the parser accepts" do
    assert "pane" in Argv.verbs()
    assert "rollback" in Argv.verbs()
    refute "frobnicate" in Argv.verbs()
  end
end
