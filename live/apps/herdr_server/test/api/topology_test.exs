defmodule HerdrServer.Api.TopologyTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrServer.Api.{Listener, Spec}
  alias HerdrServer.App.Store
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Pane.Rows
  alias HerdrServer.Test.ApiClient

  setup do
    Store.reset()
    on_exit(&Store.reset/0)
    dir = Path.join(System.tmp_dir!(), "hlt#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "a.sock")
    start_supervised!({Listener, [path: path, reload_server: :no_reload_server]})
    %{s: ApiClient.connect(path)}
  end

  defp ok!(s, method, params \\ nil) do
    reply = ApiClient.call(s, method, params)
    assert %{"result" => r} = reply, "#{method}: #{inspect(reply)}"
    assert Spec.validate_result(method, r) == :ok
    r
  end

  defp err(s, method, params) do
    assert %{"error" => %{"code" => code, "message" => msg}} = ApiClient.call(s, method, params)
    {:ok, m} = Spec.fetch(method)
    assert String.to_existing_atom(code) in (m.errors ++ [:internal]), "#{method}: #{code}"
    {code, msg}
  end

  defp focused_ws(s) do
    [w] = for w <- ok!(s, "workspace.list")["workspaces"], w["focused"], do: w["workspace_id"]
    w
  end

  test "workspace.list initialises a fresh app", %{s: s} do
    assert [%{"workspace_id" => "w1", "label" => "1", "focused" => true}] =
             ok!(s, "workspace.list")["workspaces"]
  end

  test "workspace create, get, focus, rename, close", %{s: s} do
    r = ok!(s, "workspace.create", %{"label" => "build"})
    assert r["workspace"]["workspace_id"] == "w2"
    assert r["workspace"]["label"] == "build"
    assert r["root_pane"]["pane_id"] == "p2"
    assert r["tab"]["tab_id"] == "w2:t1"
    # focus false keeps w1 focused
    assert focused_ws(s) == "w1"
    assert ok!(s, "workspace.get", %{"workspace_id" => "w2"})["workspace"]["tabs"] == 1

    assert ok!(s, "workspace.focus", %{"workspace_id" => "w2"})["workspace"]["focused"]
    assert focused_ws(s) == "w2"

    renamed = ok!(s, "workspace.rename", %{"workspace_id" => "w2", "label" => "ops"})
    assert renamed["workspace"]["label"] == "ops"

    assert ok!(s, "workspace.close", %{"workspace_id" => "w2"})["workspace_id"] == "w2"
    assert length(ok!(s, "workspace.list")["workspaces"]) == 1
    assert focused_ws(s) == "w1"
  end

  test "workspace.create with focus focuses it", %{s: s} do
    ok!(s, "workspace.create", %{"focus" => true})
    assert focused_ws(s) == "w2"
  end

  test "closing the last workspace fails", %{s: s} do
    ok!(s, "workspace.list")

    assert {"failed", "cannot close the last workspace"} =
             err(s, "workspace.close", %{"workspace_id" => "w1"})
  end

  test "tab create, list, get, focus, rename, close", %{s: s} do
    ok!(s, "workspace.list")
    r = ok!(s, "tab.create", %{"label" => "logs"})
    assert r["tab"]["tab_id"] == "w1:t2"
    assert r["tab"]["label"] == "logs"
    refute r["tab"]["focused"]
    assert r["root_pane"]["pane_id"] == "p2"

    assert length(ok!(s, "tab.list")["tabs"]) == 2
    assert length(ok!(s, "tab.list", %{"workspace_id" => "w1"})["tabs"]) == 2
    assert ok!(s, "tab.get", %{"tab_id" => "w1:t2"})["tab"]["panes"] == 1

    assert ok!(s, "tab.focus", %{"tab_id" => "w1:t2"})["tab"]["focused"]
    assert ok!(s, "tab.rename", %{"tab_id" => "w1:t2", "label" => "x"})["tab"]["label"] == "x"
    assert ok!(s, "tab.close", %{"tab_id" => "w1:t2"})["tab_id"] == "w1:t2"
    assert [%{"tab_id" => "w1:t1"}] = ok!(s, "tab.list")["tabs"]
  end

  test "tab.create with focus in another workspace activates that workspace", %{s: s} do
    ok!(s, "workspace.create")
    r = ok!(s, "tab.create", %{"workspace_id" => "w2", "focus" => true})
    assert r["tab"]["focused"]
    assert r["root_pane"]["focused"]
    assert focused_ws(s) == "w2"
  end

  test "closing the only tab leaves a fresh tab", %{s: s} do
    ok!(s, "workspace.list")
    assert ok!(s, "tab.close", %{"tab_id" => "w1:t1"})["tab_id"] == "w1:t1"
    assert [%{"panes" => 1}] = ok!(s, "tab.list")["tabs"]
    assert [%{"pane_id" => "p2"}] = ok!(s, "pane.list")["panes"]
  end

  test "pane list, get, current, split, focus, layout, close", %{s: s} do
    ok!(s, "workspace.list")
    assert [%{"pane_id" => "p1"}] = ok!(s, "pane.list")["panes"]
    assert ok!(s, "pane.get", %{"pane_id" => "p1"})["pane"]["focused"]
    assert ok!(s, "pane.current")["pane"]["pane_id"] == "p1"

    split = ok!(s, "pane.split", %{"direction" => "right"})["pane"]
    assert split["pane_id"] == "p2"
    refute split["focused"]
    assert ok!(s, "pane.current")["pane"]["pane_id"] == "p1"

    focused = ok!(s, "pane.split", %{"pane_id" => "p2", "direction" => "down", "focus" => true})
    assert focused["pane"]["focused"]
    assert ok!(s, "pane.current")["pane"]["pane_id"] == "p3"
    assert ok!(s, "pane.current", %{"caller_pane_id" => "p1"})["pane"]["pane_id"] == "p1"

    assert length(ok!(s, "pane.list", %{"tab_id" => "w1:t1"})["panes"]) == 3
    assert length(ok!(s, "pane.list", %{"workspace_id" => "w1"})["panes"]) == 3

    assert ok!(s, "pane.focus", %{"pane_id" => "p2"})["pane"]["focused"]

    layout = ok!(s, "pane.layout", %{"pane_id" => "p3"})["layout"]
    assert layout["focused_pane_id"] == "p2"
    assert %{"type" => "split", "direction" => "right", "ratio" => 0.5} = layout["root"]

    assert ok!(s, "pane.close", %{"pane_id" => "p3"})["pane_id"] == "p3"
    assert length(ok!(s, "pane.list")["panes"]) == 2
  end

  test "pane.rename sets and clears the pane's name", %{s: s} do
    ok!(s, "workspace.list")
    name = fn -> Map.get(Store.snapshot().session.panes[1], :name) end

    assert ok!(s, "pane.rename", %{"pane_id" => "p1", "label" => "logs"})["pane"]["pane_id"] ==
             "p1"

    assert name.() == "logs"
    ok!(s, "pane.rename", %{"pane_id" => "p1", "label" => ""})
    assert name.() == nil
    ok!(s, "pane.rename", %{"pane_id" => "p1", "label" => "again"})
    ok!(s, "pane.rename", %{"pane_id" => "p1"})
    assert name.() == nil
  end

  test "pane.split of a pane closed meanwhile is not_found", %{s: s} do
    ok!(s, "workspace.list")
    ok!(s, "pane.split", %{"direction" => "right"})
    ok!(s, "pane.close", %{"pane_id" => "p2"})
    assert {"not_found", _} = err(s, "pane.split", %{"pane_id" => "p2", "direction" => "right"})
    assert {"not_found", _} = err(s, "pane.close", %{"pane_id" => "p2"})
    assert {"not_found", _} = err(s, "pane.focus", %{"pane_id" => "p2"})
  end

  test "splitting a tiny pane fails", %{s: s} do
    ok!(s, "workspace.list")

    msg =
      Enum.find_value(1..12, fn _ ->
        case ApiClient.call(s, "pane.split", %{"direction" => "down", "focus" => true}) do
          %{"error" => %{"code" => "failed", "message" => m}} -> m
          %{"result" => _} -> nil
        end
      end)

    assert msg == "pane too small to split"
  end

  test "pane.process_info reads the pty facts", %{s: s} do
    ok!(s, "workspace.list")

    assert %{"pane_id" => "p1", "os_pid" => _, "cwd" => nil, "exited" => false} =
             ok!(s, "pane.process_info", %{"pane_id" => "p1"})

    {:ok, %{pty: pty}} = Fake.Keeper.lookup(Rows.kernel_id(1))
    # mark it exited without the exit event, which would close the pane
    :sys.replace_state(pty, &%{&1 | closed: true})
    assert ok!(s, "pane.process_info", %{"pane_id" => "p1"})["exited"]
  end

  test "process_info of a pane whose kernel is gone is not_found", %{s: s} do
    ok!(s, "workspace.list")
    kid = Rows.kernel_id(1)
    on_exit(fn -> Rows.put_kernel_id(1, kid) end)
    :ok = Rows.put_kernel_id(1, 987_654)
    assert {"not_found", _} = err(s, "pane.process_info", %{"pane_id" => "p1"})
  end

  test "a crash inside a command answers internal, not not_found", %{s: s} do
    ok!(s, "workspace.list")
    # a next id no command can count on: the command raises inside the Store's guard
    :sys.replace_state(Store, fn st -> put_in(st.app.session.next_id, :bogus) end)

    assert {"internal", msg} = err(s, "pane.split", %{"pane_id" => "p1", "direction" => "right"})
    assert msg =~ "action failed"
    assert {"internal", _} = err(s, "workspace.create", %{})
    assert {"internal", _} = err(s, "tab.create", %{})
  end

  test "unknown ids are not_found for every method taking one", %{s: s} do
    ok!(s, "workspace.list")
    w = %{"workspace_id" => "w9"}
    t = %{"tab_id" => "w1:t9"}
    p = %{"pane_id" => "p99"}

    for {m, params} <- [
          {"workspace.get", w},
          {"workspace.focus", w},
          {"workspace.rename", Map.put(w, "label", "x")},
          {"workspace.close", w},
          {"tab.list", w},
          {"tab.get", t},
          {"tab.create", w},
          {"tab.focus", t},
          {"tab.rename", Map.put(t, "label", "x")},
          {"tab.close", t},
          {"pane.list", w},
          {"pane.list", t},
          {"pane.get", p},
          {"pane.current", %{"caller_pane_id" => "p99"}},
          {"pane.split", Map.put(p, "direction", "right")},
          {"pane.close", p},
          {"pane.focus", p},
          {"pane.layout", p},
          {"pane.process_info", p},
          {"pane.rename", Map.put(p, "label", "x")}
        ] do
      assert {"not_found", _} = err(s, m, params), m
    end
  end
end
