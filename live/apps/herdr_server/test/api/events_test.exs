defmodule HerdrServer.Api.EventsTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrServer.Api.{Events, Listener, Spec}
  alias HerdrServer.App.Store
  alias HerdrServer.Test.ApiClient

  setup do
    Store.reset()
    on_exit(&Store.reset/0)
    dir = Path.join(System.tmp_dir!(), "hle#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "a.sock")
    start_supervised!(Events)
    start_supervised!({Listener, [path: path, reload_server: :no_reload_server]})
    ctl = ApiClient.connect(path)
    ApiClient.call(ctl, "workspace.list")
    %{path: path, ctl: ctl}
  end

  defp subscribe(path, subs, id \\ "sub") do
    s = ApiClient.connect(path)
    reply = ApiClient.call(s, "events.subscribe", %{"subscriptions" => subs}, id)
    {s, reply}
  end

  # the next event line, checked against the Spec's event schema
  defp event!(s, timeout \\ 10_000) do
    line = ApiClient.recv_line(s, timeout)
    assert Spec.validate_event(line) == :ok, inspect(line)
    line
  end

  defp declared!(%{"error" => %{"code" => code}} = reply) do
    {:ok, m} = Spec.fetch("events.subscribe")
    assert String.to_existing_atom(code) in (m.errors ++ [:internal]), inspect(reply)
    reply
  end

  defp store_subscriber?(pid), do: Map.has_key?(:sys.get_state(Store).subs, pid)

  defp wait_until(f, n \\ 400) do
    cond do
      f.() -> :ok
      n == 0 -> flunk("condition never held")
      true -> Process.sleep(25) && wait_until(f, n - 1)
    end
  end

  defp subscribe!(path, subs) do
    {s, reply} = subscribe(path, subs)
    assert %{"id" => "sub", "result" => r} = reply, inspect(reply)
    assert Spec.validate_result("events.subscribe", r) == :ok
    assert r["subscriptions"] == length(subs)
    s
  end

  test "a pane.created subscriber gets the split's new pane", %{path: path, ctl: ctl} do
    s = subscribe!(path, [%{"type" => "pane.created"}])

    assert %{"result" => _} =
             ApiClient.call(ctl, "pane.split", %{"pane_id" => "p1", "direction" => "right"})

    assert %{"event" => "pane.created", "data" => data} = event!(s)
    assert data["pane"]["pane_id"] == "p2"
    assert data["pane_id"] == "p2"
    assert ApiClient.recv_line(s, 300) == {:error, :timeout}
  end

  test "a pane_id filter excludes other panes", %{path: path, ctl: ctl} do
    s = subscribe!(path, [%{"type" => "pane.focused", "pane_id" => "p1"}])

    ApiClient.call(ctl, "pane.split", %{
      "pane_id" => "p1",
      "direction" => "right",
      "focus" => true
    })

    ApiClient.call(ctl, "pane.focus", %{"pane_id" => "p1"})

    assert %{"event" => "pane.focused", "data" => %{"pane_id" => "p1"}} = event!(s)
  end

  test "notification.show reaches the Store's subscribers and notification.shown", %{
    path: path,
    ctl: ctl
  } do
    Store.subscribe(self())
    s = subscribe!(path, [%{"type" => "notification.shown"}])

    assert %{"result" => %{"type" => "ok"}} =
             ApiClient.call(ctl, "notification.show", %{"title" => "t", "pane_id" => "p1"})

    assert_receive {:alert, %{title: "t", body: "", pane: 1, sound: :request}}
    assert %{"event" => "notification.shown", "data" => %{"title" => "t"}} = event!(s)

    assert %{"result" => _} = ApiClient.call(ctl, "notification.show", %{"title" => "u"})
    assert_receive {:alert, %{title: "u", pane: nil}}
  end

  test "an agent notification is published as notification.shown", %{path: path} do
    s = subscribe!(path, [%{"type" => "notification.shown", "pane_id" => "p1"}])
    Store.event_async({:agent_state, 1, :working})
    Store.event_async({:agent_state, 1, :blocked})

    assert %{"event" => "notification.shown", "data" => data} = event!(s)

    assert data == %{
             "pane_id" => "p1",
             "tab_id" => "w1:t1",
             "workspace_id" => "w1",
             "level" => "attention",
             "title" => "agent needs attention",
             "body" => "1 · 1",
             "sound" => "request"
           }

    assert ApiClient.recv_line(s, 300) == {:error, :timeout}
  end

  test "an alert that is not a notification is not published", %{path: path} do
    s = subscribe!(path, [%{"type" => "notification.shown"}])
    a = %{kind: :bell, pane: 1, level: :info, title: "t", body: "b", sound: nil}
    send(HerdrServer.Api.Events, {:alert, a})
    assert ApiClient.recv_line(s, 300) == {:error, :timeout}
  end

  test "request lines on a subscription are ignored", %{path: path, ctl: ctl} do
    s = subscribe!(path, [%{"type" => "tab.created"}])
    ApiClient.send_line(s, ~s({"id":"x","method":"ping"}))
    ApiClient.call(ctl, "tab.create", %{})
    assert %{"event" => "tab.created"} = event!(s)
  end

  test "an unknown id answers not_found and closes", %{path: path} do
    {s, reply} =
      subscribe(path, [%{"type" => "pane.created"}, %{"type" => "pane.closed", "pane_id" => "p9"}])

    assert %{"id" => "sub", "error" => %{"code" => "not_found"}} = declared!(reply)
    assert ApiClient.recv_line(s, 5000) == {:error, :closed}

    {s, reply} = subscribe(path, [%{"type" => "tab.closed", "tab_id" => "w1:t7"}])
    assert %{"error" => %{"code" => "not_found"}} = declared!(reply)
    assert ApiClient.recv_line(s, 5000) == {:error, :closed}
  end

  test "a subscriber that falls behind gets events_lost and is closed", %{path: path} do
    s = subscribe!(path, [%{"type" => "pane.updated"}])
    app = Store.snapshot()
    a = put_in(app.session.panes[1].title, "a")
    b = put_in(app.session.panes[1].title, "b")
    for i <- 1..1500, do: send(Events, {:app_changed, if(rem(i, 2) == 0, do: a, else: b)})
    # every event is in the conn's mailbox once the hub answers
    _ = :sys.get_state(Events)

    lines = read_until_error(s, [])
    assert %{"id" => "sub", "error" => %{"code" => "events_lost"}} = declared!(hd(lines))
    assert length(lines) < 1500
    assert ApiClient.recv_line(s, 5000) == {:error, :closed}
  end

  test "after a Store restart the hub subscribes again and events still flow", %{
    path: path,
    ctl: ctl
  } do
    s = subscribe!(path, [%{"type" => "pane.created"}])
    hub = Process.whereis(Events)
    assert store_subscriber?(hub)
    # let the mirror catch up, then a supervised stop and restart (no restart intensity)
    Process.sleep(100)
    :ok = Supervisor.terminate_child(HerdrServer.Supervisor, Store)
    {:ok, _} = Supervisor.restart_child(HerdrServer.Supervisor, Store)
    wait_until(fn -> store_subscriber?(hub) end)

    assert %{"result" => _} =
             ApiClient.call(ctl, "pane.split", %{"pane_id" => "p1", "direction" => "right"})

    assert %{"event" => "pane.created", "data" => %{"pane_id" => "p2"}} = event!(s)
  end

  test "a hub that stops ends each stream with events_lost", %{path: path} do
    s = subscribe!(path, [%{"type" => "pane.created"}])
    Process.exit(Process.whereis(Events), :kill)

    assert %{"id" => "sub", "error" => %{"code" => "events_lost"}} =
             declared!(ApiClient.recv_line(s))

    assert ApiClient.recv_line(s, 5000) == {:error, :closed}
  end

  test "the hub is a Store subscriber only while it has subscribers", %{path: path} do
    hub = Process.whereis(Events)
    refute store_subscriber?(hub)
    s = subscribe!(path, [%{"type" => "pane.created"}])
    assert store_subscriber?(hub)
    :gen_tcp.close(s)
    wait_until(fn -> not store_subscriber?(hub) end)
    assert :sys.get_state(hub).last == nil
  end

  test "with no hub, events.subscribe is not_available", %{path: path} do
    stop_supervised!(Events)
    {s, reply} = subscribe(path, [%{"type" => "pane.created"}])
    assert %{"error" => %{"code" => "not_available"}} = declared!(reply)
    assert ApiClient.recv_line(s, 5000) == {:error, :closed}
  end

  defp read_until_error(s, acc) do
    case ApiClient.recv_line(s) do
      %{"error" => _} = e -> [e | acc]
      %{"event" => _} = ev -> read_until_error(s, [ev | acc])
    end
  end

  test "tab.move and a chrome drop publish tab.moved once; workspace.move workspace.moved",
       %{path: path, ctl: ctl} do
    s = subscribe!(path, [%{"type" => "tab.moved"}, %{"type" => "workspace.moved"}])
    ApiClient.call(ctl, "tab.create", %{})
    ApiClient.call(ctl, "tab.create", %{})

    ApiClient.call(ctl, "tab.move", %{"tab_id" => "w1:t1", "insert_index" => 3})
    assert %{"event" => "tab.moved", "data" => data} = event!(s)
    assert %{"tab_id" => "w1:t1", "workspace_id" => "w1", "insert_index" => 3} = data
    assert Enum.map(data["tabs"], & &1["tab_id"]) == ~w(w1:t2 w1:t3 w1:t1)

    # a drag of t1 (now last) onto t2 (first): gap 0
    over = %{x: 0, y: 0, over: [:tabs, {:tab, 2}]}
    Store.event({:chrome, [:tabs, {:tab, 1}], {:drop, over}}, %{cols: 80, rows: 24})
    assert %{"event" => "tab.moved", "data" => %{"insert_index" => 0} = data} = event!(s)
    assert Enum.map(data["tabs"], & &1["tab_id"]) == ~w(w1:t1 w1:t2 w1:t3)

    ApiClient.call(ctl, "workspace.create", %{})
    ApiClient.call(ctl, "workspace.move", %{"workspace_id" => "w2", "insert_index" => 0})
    assert %{"event" => "workspace.moved", "data" => data} = event!(s)
    assert %{"workspace_id" => "w2", "insert_index" => 0} = data
    assert Enum.map(data["workspaces"], & &1["workspace_id"]) == ~w(w2 w1)

    # a move to where it is publishes nothing
    ApiClient.call(ctl, "workspace.move", %{"workspace_id" => "w2", "insert_index" => 1})
    assert ApiClient.recv_line(s, 300) == {:error, :timeout}
  end
end
