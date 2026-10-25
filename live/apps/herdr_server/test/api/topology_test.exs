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
    %{s: ApiClient.connect(path), dir: dir}
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

  test "pane.zoom focuses the pane, then sets or toggles the tab's zoom", %{s: s} do
    ok!(s, "workspace.list")
    ok!(s, "pane.split", %{"direction" => "right"})
    zoom = fn -> Map.get(hd(hd(Store.snapshot().session.workspaces).tabs), :zoom) end

    assert ok!(s, "pane.zoom", %{"pane_id" => "p1"})["pane"]["focused"]
    assert zoom.() == 1
    ok!(s, "pane.zoom", %{"pane_id" => "p1", "zoom" => true})
    assert zoom.() == 1
    ok!(s, "pane.zoom", %{"pane_id" => "p1"})
    assert zoom.() == nil
    # focusing the pane the zoom hides clears it before the toggle zooms that pane
    ok!(s, "pane.zoom", %{"pane_id" => "p1"})
    ok!(s, "pane.zoom", %{"pane_id" => "p2"})
    assert zoom.() == 2
    ok!(s, "pane.zoom", %{"zoom" => false})
    assert zoom.() == nil
  end

  test "pane.split with cwd and env spawns there; HERDR_* stay authoritative", %{s: s, dir: dir} do
    ok!(s, "workspace.list")

    ok!(s, "pane.split", %{
      "direction" => "right",
      "cwd" => dir,
      "env" => %{"X" => "1", "HERDR_PANE_ID" => "p9"}
    })

    spec = Fake.Keeper.last_spec()
    assert spec.cwd == dir
    assert {"X", "1"} in spec.env
    assert {"HERDR_PANE_ID", "p2"} in spec.env
    refute {"HERDR_PANE_ID", "p9"} in spec.env
  end

  test "pane.split with a missing cwd is invalid_params and spawns nothing", %{s: s, dir: dir} do
    ok!(s, "workspace.list")
    missing = Path.join(dir, "nope")

    assert {"invalid_params", _} =
             err(s, "pane.split", %{"direction" => "right", "cwd" => missing})

    assert length(ok!(s, "pane.list")["panes"]) == 1
  end

  test "pane.split validates cwd and env", %{s: s, dir: dir} do
    ok!(s, "workspace.list")
    base = %{"direction" => "right"}

    for bad <- [
          %{"cwd" => "relative"},
          %{"cwd" => dir <> <<0>>},
          %{"env" => %{"" => "x"}},
          %{"env" => %{"A=B" => "x"}},
          %{"env" => %{"A" => <<"x", 0>>}},
          %{"env" => %{<<"A", 0>> => "x"}}
        ] do
      assert {"invalid_params", _} = err(s, "pane.split", Map.merge(base, bad))
    end

    assert length(ok!(s, "pane.list")["panes"]) == 1
  end

  test "pane.focus_direction, swap and resize by id, each clearing zoom", %{s: s} do
    ok!(s, "workspace.list")
    ok!(s, "pane.split", %{"direction" => "right"})
    zoom = fn -> Map.get(hd(hd(Store.snapshot().session.workspaces).tabs), :zoom) end

    ok!(s, "pane.zoom", %{"pane_id" => "p1"})
    r = ok!(s, "pane.focus_direction", %{"pane_id" => "p1", "direction" => "right"})
    assert %{"changed" => true, "source_pane_id" => "p1", "focused_pane_id" => "p2"} = r
    assert zoom.() == nil
    r = ok!(s, "pane.focus_direction", %{"pane_id" => "p2", "direction" => "right"})
    assert %{"changed" => false, "focused_pane_id" => "p2"} = r

    ok!(s, "pane.zoom", %{"pane_id" => "p1"})
    r = ok!(s, "pane.swap", %{"pane_id" => "p1", "direction" => "right"})
    assert %{"changed" => true, "source_pane_id" => "p1", "focused_pane_id" => "p1"} = r
    assert zoom.() == nil
    assert %{"changed" => false} = ok!(s, "pane.swap", %{"direction" => "right"})

    ok!(s, "pane.zoom", %{"pane_id" => "p1"})
    r = ok!(s, "pane.resize", %{"pane_id" => "p1", "direction" => "left", "amount" => 0.1})
    assert %{"changed" => true, "pane_id" => "p1"} = r
    assert zoom.() == nil

    assert %{"changed" => false, "reason" => "no_neighbor"} =
             ok!(s, "pane.focus_direction", %{"pane_id" => "p2", "direction" => "right"})

    assert {"not_found", _} = err(s, "pane.swap", %{"pane_id" => "p9", "direction" => "left"})
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
          {"tab.move", Map.put(t, "insert_index", 0)},
          {"workspace.move", Map.put(w, "insert_index", 0)},
          {"pane.list", w},
          {"pane.list", t},
          {"pane.get", p},
          {"pane.current", %{"caller_pane_id" => "p99"}},
          {"pane.split", Map.put(p, "direction", "right")},
          {"pane.close", p},
          {"pane.focus", p},
          {"pane.zoom", p},
          {"pane.layout", p},
          {"pane.process_info", p},
          {"pane.rename", Map.put(p, "label", "x")}
        ] do
      assert {"not_found", _} = err(s, m, params), m
    end
  end

  test "tab.move and workspace.move take herdr's insert_index and answer the new order",
       %{s: s} do
    ok!(s, "workspace.list")
    ok!(s, "tab.create", %{})
    ok!(s, "tab.create", %{})
    ids = fn r -> Enum.map(r["tabs"], & &1["tab_id"]) end
    # gap 3 of 3 appends: t1 goes last
    assert ids.(ok!(s, "tab.move", %{"tab_id" => "w1:t1", "insert_index" => 3})) ==
             ~w(w1:t2 w1:t3 w1:t1)

    # gap 1 (before t3) moves t1 left of t3
    assert ids.(ok!(s, "tab.move", %{"tab_id" => "w1:t1", "insert_index" => 1})) ==
             ~w(w1:t2 w1:t1 w1:t3)

    assert {"failed", "insert_index 4 is out of bounds"} =
             err(s, "tab.move", %{"tab_id" => "w1:t1", "insert_index" => 4})

    ok!(s, "workspace.create", %{})
    r = ok!(s, "workspace.move", %{"workspace_id" => "w2", "insert_index" => 0})
    assert Enum.map(r["workspaces"], & &1["workspace_id"]) == ~w(w2 w1)
    assert focused_ws(s) == "w1"

    assert {"failed", _} =
             err(s, "workspace.move", %{"workspace_id" => "w2", "insert_index" => 3})

    assert {"invalid_params", _} =
             err(s, "tab.move", %{"tab_id" => "w1:t1", "insert_index" => -1})
  end

  describe "report_metadata" do
    test "pane and workspace tokens round trip; null clears; stale seq dropped", %{s: s} do
      rep =
        &ok!(s, "pane.report_metadata", Map.merge(%{"pane_id" => "p1", "source" => "hook"}, &1))

      assert %{"type" => "ok"} =
               rep.(%{"tokens" => %{"pr" => " #12\n", "ci" => "ok"}, "seq" => 2})

      assert ok!(s, "pane.get", %{"pane_id" => "p1"})["pane"]["tokens"] == %{
               "pr" => "#12",
               "ci" => "ok"
             }

      rep.(%{"tokens" => %{"pr" => "#13"}, "seq" => 2})
      rep.(%{"tokens" => %{"ci" => nil}, "seq" => 3})
      assert ok!(s, "pane.get", %{"pane_id" => "p1"})["pane"]["tokens"] == %{"pr" => "#12"}
      rep.(%{"tokens" => %{"pr" => ""}})
      refute Map.has_key?(ok!(s, "pane.get", %{"pane_id" => "p1"})["pane"], "tokens")

      ok!(s, "workspace.report_metadata", %{
        "workspace_id" => "w1",
        "source" => "hook",
        "tokens" => %{"build" => "green"}
      })

      assert ok!(s, "workspace.get", %{"workspace_id" => "w1"})["workspace"]["tokens"] ==
               %{"build" => "green"}

      assert {"invalid_params", _} =
               err(s, "pane.report_metadata", %{
                 "pane_id" => "p1",
                 "source" => "a b",
                 "tokens" => %{"k" => "v"}
               })

      # herdr's pane_id is required: no fallback to the focused pane
      assert {"invalid_params", _} =
               err(s, "pane.report_metadata", %{"source" => "hook", "tokens" => %{"k" => "v"}})

      assert {"not_found", _} =
               err(s, "workspace.report_metadata", %{
                 "workspace_id" => "w9",
                 "source" => "hook",
                 "tokens" => %{"k" => "v"}
               })
    end

    test "ttl_ms expires a token through the Store's timer", %{s: s} do
      p = %{"pane_id" => "p1", "source" => "hook", "tokens" => %{"short" => "1"}, "ttl_ms" => 30}
      ok!(s, "pane.report_metadata", p)
      ok!(s, "pane.report_metadata", %{p | "tokens" => %{"long" => "2"}, "ttl_ms" => 60_000})

      assert ok!(s, "pane.get", %{"pane_id" => "p1"})["pane"]["tokens"] == %{
               "short" => "1",
               "long" => "2"
             }

      tokens = fn -> ok!(s, "pane.get", %{"pane_id" => "p1"})["pane"]["tokens"] end
      # poll: the timer fires about 30 ms after the report
      assert Enum.find_value(1..200, fn _ ->
               if tokens.() == %{"long" => "2"}, do: true, else: Process.sleep(10) && nil
             end)

      # one timer, armed for the long key
      assert %{expiry: {_, at}} = :sys.get_state(Store)
      assert at > System.system_time(:millisecond) + 50_000
    end
  end
end
