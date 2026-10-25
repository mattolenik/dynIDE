defmodule HerdrServer.Persist.RestorePlanTest do
  use ExUnit.Case, async: true

  alias HerdrServer.App.Actions
  alias HerdrServer.Layout
  alias HerdrServer.Persist.RestorePlan

  # two tabs of two panes: 1, 2 in tab 1 (horizontal) and 3, 4 in tab 2 (vertical)
  defp app do
    {app, _} = Actions.init(%{cols: 80, rows: 24})
    {app, _} = Actions.split(app, :horizontal)
    {app, _} = Actions.new_tab(app)
    {app, _} = Actions.split(app, :vertical)
    app
  end

  defp rects(app, tab_id) do
    s = app.session
    [ws] = s.workspaces
    tab = Enum.find(ws.tabs, &(&1.id == tab_id))
    Map.new(Layout.rects(tab.layout, s.area, Layout.opts(tab, app.ui)), &{&1.id, &1.rect})
  end

  test "one spawn per pane of every tab, sized to that tab's rects" do
    app = app()
    spawns = RestorePlan.spawns(app, %{}, %{}, fn _ -> true end)
    assert Enum.map(spawns, &elem(&1, 1)) |> Enum.sort() == [1, 2, 3, 4]

    want = Map.merge(rects(app, 1), rects(app, 2))

    for {:spawn, id, size, opts} <- spawns do
      assert size == %{cols: want[id].w, rows: want[id].h}
      assert opts == %{cwd: nil, replay: nil}
    end

    # the tabs split differently, so the sizes really come from each tab's own layout
    sizes = Map.new(spawns, fn {:spawn, id, size, _} -> {id, size} end)
    assert sizes[1] != sizes[3]
  end

  test "a deleted cwd falls back to its nearest existing ancestor, else nil" do
    app = app()
    facts = %{1 => %{cwd: "/a/b/c"}, 2 => %{cwd: "/a"}, 3 => %{cwd: "/x/y"}, 4 => %{cwd: nil}}
    exists? = &(&1 == "/a")
    cwds = Map.new(RestorePlan.spawns(app, facts, %{}, exists?), &{elem(&1, 1), elem(&1, 3).cwd})
    assert cwds == %{1 => "/a", 2 => "/a", 3 => nil, 4 => nil}
  end

  test "replay is the scrollback with an attribute reset and a new line appended" do
    spawns = RestorePlan.spawns(app(), %{}, %{2 => "hi\e[31m"}, fn _ -> true end)
    replays = Map.new(spawns, &{elem(&1, 1), elem(&1, 3).replay})
    assert replays == %{1 => nil, 2 => "hi\e[31m\e[0m\r\n", 3 => nil, 4 => nil}
  end
end
