defmodule DynideServer.Api.SpecTest do
  use ExUnit.Case, async: true

  alias DynideServer.Api.Spec
  alias DynideServer.Api.Spec.Doc

  test "every method name is unique and every error is a known code" do
    methods = Spec.methods()
    names = Enum.map(methods, & &1.name)
    assert names == Enum.uniq(names)
    assert length(names) == 82

    for m <- methods do
      assert Enum.all?(m.errors, &(&1 in Spec.error_codes())), m.name
      assert Map.has_key?(Spec.results(), m.result), "#{m.name} -> #{m.result}"
      assert {:ok, ^m} = Spec.fetch(m.name)
      if m.params != [], do: assert(:invalid_params in m.errors, m.name)
    end

    assert Spec.fetch("nope") == :error

    assert Spec.error_codes() ==
             ~w(parse_error invalid_request unknown_method invalid_params not_found
                not_available failed timeout backpressure events_lost ui_busy internal)a
  end

  test "popup sizes are herdr's: integer cells or a percent string" do
    base = %{"plugin_id" => "x", "entrypoint" => "p", "placement" => "popup"}

    ok =
      Spec.validate_params(
        "plugin.pane.open",
        Map.merge(base, %{"width" => 64, "height" => "70%"})
      )

    assert {:ok, %{width: 64, height: "70%"}} = ok

    for bad <- ["120", "0%", "101%", -1, 1.5, true] do
      assert {:error, _} = Spec.validate_params("plugin.pane.open", Map.put(base, "width", bad))
    end
  end

  test "validate_params parses ids and rejects unknown keys" do
    assert Spec.validate_params("pane.split", %{"pane_id" => "p2", "direction" => "right"}) ==
             {:ok, %{pane_id: 2, direction: "right"}}

    assert {:error, msg} = Spec.validate_params("pane.split", %{"bogus" => 1})
    assert msg =~ "bogus"

    assert {:error, msg} =
             Spec.validate_params("pane.split", %{"pane_id" => "p2", "direction" => "left"})

    assert msg =~ "direction"

    assert {:error, msg} =
             Spec.validate_params("pane.split", %{"pane_id" => "2", "direction" => "right"})

    assert msg =~ "pane_id"

    assert Spec.validate_params("tab.get", %{"tab_id" => "w1:t2"}) == {:ok, %{tab_id: {1, 2}}}
    assert Spec.validate_params("ping", %{}) == {:ok, %{}}
    assert {:error, _} = Spec.validate_params("nope", %{})
  end

  test "ranges, lists and objects" do
    assert {:error, msg} = Spec.validate_params("reload.rollback", %{"n" => 0})
    assert msg =~ "n"
    assert Spec.validate_params("reload.rollback", %{"n" => 3}) == {:ok, %{n: 3}}

    assert {:error, _} =
             Spec.validate_params("pane.split", %{"direction" => "down", "ratio" => 0.95})

    assert {:ok, %{ratio: 0.5, focus: true}} =
             Spec.validate_params("pane.split", %{
               "direction" => "down",
               "ratio" => 0.5,
               "focus" => true
             })

    assert {:error, msg} =
             Spec.validate_params("pane.send_keys", %{"pane_id" => "p1", "keys" => []})

    assert msg =~ "keys"

    assert Spec.validate_params("events.subscribe", %{
             "subscriptions" => [%{"type" => "pane.updated", "pane_id" => "p4"}]
           }) == {:ok, %{subscriptions: [%{type: "pane.updated", pane_id: 4}]}}

    assert {:error, msg} =
             Spec.validate_params("events.subscribe", %{
               "subscriptions" => [%{"type" => "pane.updated", "extra" => 1}]
             })

    assert msg =~ "extra"
    assert {:error, _} = Spec.validate_params("events.subscribe", %{"subscriptions" => []})
  end

  test "required params" do
    assert {:error, msg} = Spec.validate_params("pane.read", %{})
    assert msg =~ "pane_id"
    assert {:ok, %{pane_id: 1}} = Spec.validate_params("pane.read", %{"pane_id" => "p1"})
  end

  test "validate_result checks type and fields" do
    pane = %{
      "pane_id" => "p1",
      "tab_id" => "w1:t1",
      "workspace_id" => "w1",
      "title" => nil,
      "label" => nil,
      "focused" => true,
      "cols" => 80,
      "rows" => 24
    }

    assert Spec.validate_result("pane.get", %{"type" => "pane_info", "pane" => pane}) == :ok

    assert {:error, msg} =
             Spec.validate_result("pane.get", %{"type" => "pane_list", "panes" => []})

    assert msg =~ "type"
    assert {:error, msg} = Spec.validate_result("pane.get", %{"type" => "pane_info"})
    assert msg =~ "pane"

    assert {:error, msg} =
             Spec.validate_result("pane.get", %{
               "type" => "pane_info",
               "pane" => %{pane | "cols" => "x"}
             })

    assert msg =~ "cols"
    assert Spec.validate_result("pane.send_text", %{"type" => "ok"}) == :ok

    assert Spec.validate_result("ping", %{"type" => "pong", "version" => "0.1.0", "gen" => 1}) ==
             :ok
  end

  test "api.md is generated from the spec" do
    assert File.read!(Doc.path()) == Doc.markdown(),
           "docs/dynide/api.md is stale: run `mix dynide.api.docs` from dynide/"
  end

  test "m11 agent detection contract" do
    for n <-
          ~w(server.agent_manifests server.reload_agent_manifests pane.report_agent pane.release_agent) do
      assert {:ok, _} = Spec.fetch(n), n
    end

    assert {:ok, %{result: "agent_manifests", params: []}} = Spec.fetch("server.agent_manifests")

    assert Spec.validate_params("agent.explain", %{"agent" => "claude", "text" => "x"}) ==
             {:ok, %{agent: "claude", text: "x"}}

    assert {:ok, %{pane_id: 1, state: "idle", seq: 0}} =
             Spec.validate_params("pane.report_agent", %{
               "pane_id" => "p1",
               "source" => "s",
               "agent" => "a",
               "state" => "idle",
               "seq" => 0,
               "resume_argv" => ["x"]
             })

    assert {:error, _} =
             Spec.validate_params("pane.report_agent", %{
               "pane_id" => "p1",
               "source" => "s",
               "agent" => "a",
               "state" => "done"
             })

    data = %{
      "workspace_id" => "w1",
      "tab_id" => "w1:t1",
      "pane_id" => "p1",
      "agent" => "claude",
      "agent_status" => "working"
    }

    assert Spec.validate_event(%{"event" => "pane.agent_status_changed", "data" => data}) == :ok

    assert Spec.validate_event(%{
             "event" => "pane.agent_detected",
             "data" => Map.delete(data, "agent_status")
           }) == :ok

    agent = %{
      "pane_id" => "p1",
      "workspace_id" => "w1",
      "tab_id" => "w1:t1",
      "agent" => nil,
      "agent_status" => "unknown",
      "title" => nil,
      "terminal_title" => nil,
      "terminal_title_stripped" => nil,
      "focused" => false,
      "cwd" => nil,
      "screen_detection_skipped" => false,
      "hook_source" => nil
    }

    assert Spec.validate_result("agent.get", %{"type" => "agent_info", "agent" => agent}) == :ok

    assert {:error, _} =
             Spec.validate_result("agent.get", %{"type" => "agent_info", "agent" => %{}})
  end

  test "m14 methods and their params" do
    params = fn name ->
      {:ok, m} = Spec.fetch(name)
      Map.new(m.params, &{&1.name, {&1.type, &1.required}})
    end

    assert params.("pane.rename") == %{
             "pane_id" => {:pane_id, true},
             "label" => {:string, false}
           }

    assert %{
             "pane_id" => {:pane_id, true},
             "col" => {{:integer, 0, _}, true},
             "viewport_row" => {{:integer, 0, _}, true},
             "modifiers" => {{:list, {:enum, ~w(shift alt ctrl)}}, false}
           } = params.("pane.link.activate")

    assert params.("plugin.list") == %{"plugin_id" => {:string, false}}

    assert params.("plugin.install") == %{
             "source" => {:string, true},
             "ref" => {:string, false},
             "yes" => {:boolean, false}
           }

    assert params.("plugin.link") == %{"path" => {:string, true}, "enabled" => {:boolean, false}}
    assert params.("plugin.uninstall") == %{"target" => {:string, true}}

    for m <- ~w(plugin.enable plugin.disable plugin.config_dir),
        do: assert(params.(m) == %{"plugin_id" => {:string, true}}, m)

    assert params.("plugin.action.list") == %{"plugin_id" => {:string, false}}

    assert params.("plugin.action.invoke") == %{
             "action_id" => {:string, true},
             "plugin_id" => {:string, false},
             "context" => {:object, false}
           }

    assert params.("plugin.log.list") == %{
             "plugin_id" => {:string, false},
             "limit" => {{:integer, 1, 200}, false}
           }

    assert params.("plugin.pane.open") == %{
             "plugin_id" => {:string, true},
             "entrypoint" => {:string, true},
             "placement" => {{:enum, ~w(overlay popup split tab zoomed)}, false},
             "width" => {:popup_size, false},
             "height" => {:popup_size, false},
             "workspace_id" => {:workspace_id, false},
             "target_pane_id" => {:pane_id, false},
             "direction" => {{:enum, ~w(right down)}, false},
             "cwd" => {:string, false},
             "env" => {{:map, :string}, false},
             "focus" => {:boolean, false}
           }

    for m <- ~w(plugin.pane.focus plugin.pane.close),
        do: assert(params.(m) == %{"pane_id" => {:pane_id, true}}, m)

    assert {:ok, %{context: %{"a" => [1]}}} =
             Spec.validate_params("plugin.action.invoke", %{
               "action_id" => "x",
               "context" => %{"a" => [1]}
             })

    assert {:error, _} =
             Spec.validate_params("plugin.action.invoke", %{"action_id" => "x", "context" => 1})

    plugin = Map.new(Spec.objects()["plugin"], &{&1.name, &1.type})

    assert plugin == %{
             "plugin_id" => :string,
             "name" => :string,
             "version" => :string,
             "min_herdr_version" => :string,
             "description" => :null_or_string,
             "plugin_root" => :string,
             "manifest_path" => :string,
             "enabled" => :boolean,
             "source" => :object,
             "warnings" => {:list, :string},
             "error" => :null_or_string,
             "actions" => {:list, :object},
             "panes" => {:list, :object},
             "link_handlers" => {:list, :object},
             "events" => {:list, :object},
             "startup" => {:list, :object}
           }

    assert Spec.validate_result("pane.link.activate", %{
             "type" => "pane_link_activated",
             "url" => nil,
             "handled" => false
           }) == :ok
  end
end
