defmodule DynideServer.Api.SessionTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import DynideServer.Test.WireClient,
    only: [setup_listener: 0, attach: 2, recv_frame: 1, recv_until: 2, send_frame: 2]

  alias DynideServer.Api.{Listener, Spec}
  alias DynideServer.Test.ApiClient

  setup do
    ctx = setup_listener()
    dir = Path.join(System.tmp_dir!(), "hls#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "a.sock")
    start_supervised!({Listener, [path: path, reload_server: :no_reload_server]})
    Map.put(ctx, :s, ApiClient.connect(path))
  end

  defp ok!(s, method, params \\ nil) do
    reply = ApiClient.call(s, method, params)
    assert %{"result" => r} = reply, inspect(reply)
    assert Spec.validate_result(method, r) == :ok
    r
  end

  test "session.list and session.get answer this instance", %{s: s} do
    [info] = ok!(s, "session.list")["sessions"]
    assert info["name"] == "default"
    assert info["os_pid"] == String.to_integer(System.pid())
    assert ok!(s, "session.get")["session"] == info
    assert ok!(s, "session.get", %{"name" => "default"})["session"] == info
  end

  test "session.get of another name is not_found", %{s: s} do
    assert %{"error" => %{"code" => "not_found"}} =
             ApiClient.call(s, "session.get", %{"name" => "other"})
  end

  test "snapshot focus leaves out what has no focus" do
    alias DynideServer.Api.Handlers.Session

    app = fn ws, wss, pane ->
      %{session: %{active_workspace: ws, workspaces: wss}, focus: %{pane: pane}}
    end

    assert Session.focused(app.(nil, [], nil)) == %{}
    assert Session.focused(app.(2, [%{id: 1, active_tab: 1}], nil)) == %{}
    assert Session.focused(app.(1, [%{id: 1, active_tab: nil}], nil)) == %{workspace_id: "w1"}

    assert Session.focused(app.(1, [%{id: 1, active_tab: 2}], 3)) ==
             %{workspace_id: "w1", tab_id: "w1:t2", pane_id: "p3"}
  end

  test "snapshot ids match the list methods", %{s: s} do
    ok!(s, "workspace.create", %{"label" => "b"})
    ok!(s, "tab.create", %{"workspace_id" => "w1"})
    snap = ok!(s, "session.snapshot")

    assert snap["workspaces"] == ok!(s, "workspace.list")["workspaces"]
    assert snap["tabs"] == ok!(s, "tab.list")["tabs"]
    assert snap["panes"] == ok!(s, "pane.list")["panes"]
    assert length(snap["layouts"]) == length(snap["tabs"])

    for %{"tab_id" => t, "layout" => l} <- snap["layouts"],
        tab = Enum.find(snap["tabs"], &(&1["tab_id"] == t)),
        do: assert(l["focused_pane_id"] == tab["focused_pane_id"])

    assert %{"workspace_id" => "w1", "pane_id" => _} = snap["focused"]
  end

  describe "client.list" do
    test "shows short ids and the current size", %{s: s} = ctx do
      c = attach(ctx, client_id: "abcdefghijkl", size: %{cols: 80, rows: 24})
      assert {:attached, _} = recv_frame(c)

      :ok =
        send_frame(
          c,
          {:input, 1, {:resize, %{cols: 120, rows: 40, cell_px: nil}}}
        )

      assert wait(fn -> client(s, "abcdefgh") end, &(&1["cols"] == 120))

      assert %{"kind" => _, "target" => "session", "rows" => 40, "connected" => true} =
               client(s, "abcdefgh")

      assert ok!(s, "session.get")["session"]["clients"] >= 1
    end

    test "a pane conn shows its target and is not a session client", %{s: s} = ctx do
      c = attach(ctx, client_id: "sessionclient")
      assert {:attached, _} = recv_frame(c)
      # pane 1 exists once the session client has a scene
      recv_until(c, &match?({:scene, _}, &1))
      assert ok!(s, "session.get")["session"]["clients"] == 1

      p = attach(ctx, client_id: "paneclient1", target: {:pane, 1, :observe})
      assert {:attached, _} = recv_frame(p)

      assert wait(fn -> client(s, "paneclie") end, &(&1["target"] == "pane:p1:observe"))
      assert ok!(s, "session.get")["session"]["clients"] == 1
    end
  end

  defp client(s, id), do: Enum.find(ok!(s, "client.list")["clients"], &(&1["id"] == id))

  defp wait(fun, pred, n \\ 200) do
    r = fun.()

    cond do
      r && pred.(r) -> true
      n == 0 -> false
      true -> Process.sleep(10) && wait(fun, pred, n - 1)
    end
  end
end
