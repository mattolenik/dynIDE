defmodule HerdrServer.Api.EventDiffTest do
  use ExUnit.Case, async: true

  alias HerdrServer.Api.{EventDiff, Spec}
  alias HerdrServer.App.{Actions, Commands, Metadata}

  defp app, do: elem(Actions.init(%{cols: 80, rows: 24}), 0)

  # every event, as the line Api.Conn writes, matches the Spec's event schema
  defp diff(a, b) do
    events = EventDiff.diff(a, b)

    for e <- events do
      {type, data} = Map.pop(e, "event")
      line = JSON.decode!(JSON.encode!(%{event: type, data: data}))
      assert Spec.validate_event(line) == :ok, inspect(line)
    end

    events
  end

  # a move effect's event, checked like diff/2's
  defp moved(ev, app) do
    e = EventDiff.moved(ev, app)
    {type, data} = Map.pop(e, "event")
    line = JSON.decode!(JSON.encode!(%{event: type, data: data}))
    assert Spec.validate_event(line) == :ok, inspect(line)
    e
  end

  defp types(events), do: Enum.map(events, & &1["event"])
  defp find(events, type), do: Enum.find(events, &(&1["event"] == type))

  test "nil old and identical apps give no events" do
    a = app()
    assert diff(nil, a) == []
    assert diff(a, a) == []
  end

  test "a new unfocused tab gives tab.created and pane.created" do
    a = app()
    {b, _} = Commands.create_tab(a, 1, "logs", false)
    events = diff(a, b)
    assert types(events) == ["tab.created", "pane.created"]

    assert %{"tab_id" => "w1:t2", "workspace_id" => "w1", "tab" => %{label: "logs"}} =
             find(events, "tab.created")

    assert %{"pane_id" => "p2", "tab_id" => "w1:t2", "pane" => %{pane_id: "p2"}} =
             find(events, "pane.created")
  end

  test "a new focused tab also gives tab.focused and pane.focused" do
    a = app()
    {b, _} = Commands.create_tab(a, 1, nil, true)
    events = diff(a, b)

    assert types(events) == ["tab.created", "tab.focused", "pane.created", "pane.focused"]
    assert find(events, "tab.focused")["tab"].focused
    assert find(events, "pane.focused")["pane_id"] == "p2"
  end

  test "closing a pane gives pane.closed and layout.updated" do
    {a, _} = Commands.split_pane(app(), 1, :horizontal, 0.5, false)
    {b, _} = Commands.close_pane(a, 2)
    events = diff(a, b)

    assert %{"pane_id" => "p2", "tab_id" => "w1:t1", "workspace_id" => "w1"} =
             find(events, "pane.closed")

    refute Map.has_key?(find(events, "pane.closed"), "pane")
    assert find(events, "layout.updated")
  end

  test "a title change gives pane.updated" do
    a = app()
    b = put_in(a.session.panes[1].title, "vim")

    assert [%{"event" => "pane.updated", "pane_id" => "p1", "pane" => %{title: "vim"}}] =
             diff(a, b)
  end

  test "renames give workspace.renamed and tab.renamed" do
    a = app()
    {b, _} = Commands.rename_tab(a, 1, 1, "main")

    assert [%{"event" => "tab.renamed", "tab_id" => "w1:t1", "tab" => %{label: "main"}}] =
             diff(a, b)

    {c, _} = Commands.rename_workspace(a, 1, "ops")

    assert [%{"event" => "workspace.renamed", "workspace" => %{label: "ops"}}] =
             diff(a, c)
  end

  test "workspace tokens give workspace.metadata_updated, on report and on expiry" do
    a = app()
    {b, _} = Metadata.report(a, {:workspace, 1}, %{"ci" => "ok"}, "s", 1, 10, 0)

    assert [%{"event" => "workspace.metadata_updated", "workspace" => %{tokens: %{"ci" => "ok"}}}] =
             diff(a, b)

    # a stale seq changes nothing; an expiry is an update without the token
    {c, _} = Metadata.report(b, {:workspace, 1}, %{"ci" => "no"}, "s", 1, nil, 0)
    assert diff(b, c) == []
    {d, _} = Actions.apply(b, {:metadata_expire, 10})
    assert [%{"event" => "workspace.metadata_updated", "workspace" => w}] = diff(b, d)
    refute Map.has_key?(w, :tokens)
  end

  test "pane tokens give pane.updated" do
    a = app()
    {b, _} = Metadata.report(a, {:pane, 1}, %{"pr" => "#1"}, "s", nil, nil, 0)
    assert [%{"event" => "pane.updated", "pane" => %{tokens: %{"pr" => "#1"}}}] = diff(a, b)
  end

  test "a split gives pane.created and layout.updated, in order" do
    a = app()
    {b, _} = Commands.split_pane(a, 1, :horizontal, 0.5, false)
    events = diff(a, b)
    assert ["pane.created" | _] = types(events) -- ["pane.updated"]
    assert List.last(events)["event"] == "layout.updated"
    assert find(events, "pane.created")["pane_id"] == "p2"

    assert %{"tab_id" => "w1:t1", "layout" => %{root: %{type: "split"}}} =
             find(events, "layout.updated")
  end

  test "workspace create and close, closed before created" do
    a = app()
    {b, _} = Commands.create_workspace(a, "two", true)
    events = diff(a, b)

    assert ["workspace.created", "workspace.focused", "tab.created", "tab.focused" | _] =
             types(events)

    {b, _} = Commands.create_workspace(b, "three", false)
    {c, _} = Commands.close_workspace(b, 2)
    {d, _} = Commands.create_workspace(c, "four", false)
    events = diff(b, d)
    assert find(events, "workspace.created")["workspace"].label == "four"

    assert Enum.take(types(events), 3) ==
             ["workspace.closed", "workspace.created", "workspace.focused"]

    assert find(events, "workspace.closed") == %{
             "event" => "workspace.closed",
             "workspace_id" => "w2"
           }
  end

  test "every event type is produced and matches its schema" do
    a = app()
    {b, _} = Commands.create_workspace(a, "two", true)
    {c, _} = Commands.rename_workspace(b, 2, "ops")
    {d, _} = Commands.rename_tab(c, 2, 1, "main")
    {e, _} = Commands.split_pane(d, 2, :horizontal, 0.5, false)
    f = put_in(e.session.panes[2].title, "vim")
    {g, _} = Commands.close_pane(f, 3)
    {h, _} = Commands.create_tab(g, 2, nil, true)
    {h2, [{:api_event, tm}]} = Commands.move_tab(h, 2, 2, 0)
    {h3, [{:api_event, wm}]} = Commands.move_workspace(h2, 2, 0)
    {i, _} = Commands.close_tab(h3, 2, 2)
    {j, _} = Commands.close_workspace(i, 2)

    {k, _} =
      Metadata.report(j, {:workspace, 1}, %{"ci" => "ok"}, "s", nil, nil, 0)

    steps = [a, b, c, d, e, f, g, h, h2, h3, i, j, k]

    seen =
      steps
      |> Enum.zip(tl(steps))
      |> Enum.flat_map(fn {x, y} -> types(diff(x, y)) end)
      |> Kernel.++(types([moved(tm, h2), moved(wm, h3)]))

    # notification.shown comes from the Store's alerts (Api.Events), not from a diff;
    # the agent events come from detection (M11), published ahead of their task
    not_diffed = ["notification.shown", "pane.agent_detected", "pane.agent_status_changed"]
    assert Enum.sort(Enum.uniq(seen)) == Enum.sort(Spec.event_types() -- not_diffed)
  end

  test "moves are no diff events; EventDiff.moved/2 builds them from the move effect" do
    a = app()
    {a, _} = Commands.create_tab(a, 1, "b", false)
    {a, _} = Commands.create_workspace(a, "two", false)
    {b, [{:api_event, ev}]} = Commands.move_tab(a, 1, 2, 0)
    assert diff(a, b) == []

    assert %{"tab_id" => "w1:t2", "insert_index" => 0, "tabs" => tabs} =
             moved(ev, b)

    assert Enum.map(tabs, & &1.tab_id) == ["w1:t2", "w1:t1"]

    {c, [{:api_event, ev}]} = Commands.move_workspace(a, 2, 0)
    assert diff(a, c) == []
    assert %{"workspace_id" => "w2", "insert_index" => 0, "workspaces" => wss} = moved(ev, c)
    assert Enum.map(wss, & &1.workspace_id) == ["w2", "w1"]
  end
end
