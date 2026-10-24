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

    assert %{"event" => "pane.created", "data" => data} = ApiClient.recv_line(s)
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

    assert %{"event" => "pane.focused", "data" => %{"pane_id" => "p1"}} =
             ApiClient.recv_line(s)
  end

  test "request lines on a subscription are ignored", %{path: path, ctl: ctl} do
    s = subscribe!(path, [%{"type" => "tab.created"}])
    ApiClient.send_line(s, ~s({"id":"x","method":"ping"}))
    ApiClient.call(ctl, "tab.create", %{})
    assert %{"event" => "tab.created"} = ApiClient.recv_line(s)
  end

  test "an unknown id answers not_found and closes", %{path: path} do
    {s, reply} =
      subscribe(path, [%{"type" => "pane.created"}, %{"type" => "pane.closed", "pane_id" => "p9"}])

    assert %{"id" => "sub", "error" => %{"code" => "not_found"}} = reply
    assert ApiClient.recv_line(s, 5000) == {:error, :closed}

    {s, reply} = subscribe(path, [%{"type" => "tab.closed", "tab_id" => "w1:t7"}])
    assert %{"error" => %{"code" => "not_found"}} = reply
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
    assert %{"id" => "sub", "error" => %{"code" => "events_lost"}} = hd(lines)
    assert length(lines) < 1500
    assert ApiClient.recv_line(s, 5000) == {:error, :closed}
  end

  defp read_until_error(s, acc) do
    case ApiClient.recv_line(s) do
      %{"error" => _} = e -> [e | acc]
      %{"event" => _} = ev -> read_until_error(s, [ev | acc])
    end
  end
end
