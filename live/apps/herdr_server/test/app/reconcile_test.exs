defmodule HerdrServer.App.ReconcileTest do
  use ExUnit.Case, async: true
  alias HerdrServer.App.{Actions, Reconcile}
  alias HerdrServer.App.Modal.Popup
  alias HerdrServer.Layout

  defp fresh, do: elem(Actions.init(%{cols: 100, rows: 25}), 0)

  defp pfx(app, key), do: HerdrServer.ViewHelpers.pfx(app, key)

  defp ws(app), do: hd(app.session.workspaces)
  defp tab(app, name), do: Enum.find(ws(app).tabs, &(&1.name == name))
  defp active(app), do: Enum.find(ws(app).tabs, &(&1.id == ws(app).active_tab))
  defp live(ids), do: Map.new(ids, &{&1, &1 * 10})

  # every layout id has metadata and vice versa; focus is the active tab's focus
  defp consistent!(app) do
    in_layouts = for t <- ws(app).tabs, id <- Layout.pane_ids(t.layout), do: id
    assert Enum.sort(in_layouts) == Enum.sort(Map.keys(app.session.panes))
    assert app.focus.pane == active(app).layout.focus
    assert Enum.all?(in_layouts, &(&1 < app.session.next_id))
    app
  end

  test "an open popup's live pane is kept (adopted in place), a dead one pops the popup" do
    {:ok, app, id, _} = Popup.open(fresh(), %{})
    assert Reconcile.run(app, live([1, id])) == {app, [{:adopt, id}]}

    {gone, fx} = Reconcile.run(app, live([1]))
    assert gone.focus.modal == [] and fx == [{:close, id}]
    consistent!(gone)
  end

  test "no-op when the app and the keeper agree" do
    app = pfx(fresh(), "v")
    assert Reconcile.run(app, live([1, 2])) == {app, []}
  end

  test "adopts one pane into a new scratch tab, keeping the active tab" do
    app = fresh()
    {new, eff} = Reconcile.run(app, live([1, 5]))
    assert eff == [{:adopt, 5}]
    assert Layout.pane_ids(tab(new, "scratch").layout) == [5]
    assert new.session.panes[5] == %{title: nil, layout_gen: 0}
    assert new.session.next_id == 6
    assert active(new).name == "1" and new.focus.pane == 1
    consistent!(new)
  end

  test "adopts three panes by splitting one scratch tab; reuses an existing scratch tab" do
    {new, eff} = Reconcile.run(fresh(), live([1, 7, 8, 9]))
    assert eff == [{:adopt, 7}, {:adopt, 8}, {:adopt, 9}]
    assert Layout.pane_ids(tab(new, "scratch").layout) == [7, 8, 9]
    assert new.session.next_id == 10
    consistent!(new)

    {again, _} = Reconcile.run(new, live([1, 7, 8, 9, 12]))
    assert length(ws(again).tabs) == 2
    assert Layout.pane_ids(tab(again, "scratch").layout) == [7, 8, 9, 12]
    consistent!(again)
  end

  test "drops one unfocused pane" do
    app = pfx(pfx(fresh(), "v"), "h")
    assert app.focus.pane == 1
    {new, eff} = Reconcile.run(app, live([1]))
    assert eff == [{:close, 2}]
    assert Layout.pane_ids(active(new).layout) == [1]
    assert new.focus.pane == 1
    consistent!(new)
  end

  test "dropping the focused pane moves focus to a pane of the same tab" do
    app = pfx(pfx(fresh(), "v"), "v")
    assert app.focus.pane == 3
    {new, eff} = Reconcile.run(app, live([1, 2]))
    assert eff == [{:close, 3}]
    assert new.focus.pane in [1, 2]
    consistent!(new)
  end

  test "an emptied active tab is removed and its neighbour activated" do
    # tab 1: pane 1; tab 2: pane 2 (active)
    app = HerdrServer.ViewHelpers.new_tab(fresh())
    {new, eff} = Reconcile.run(app, live([1]))
    assert eff == [{:close, 2}]
    assert Enum.map(ws(new).tabs, & &1.id) == [1]
    assert new.focus.pane == 1
    consistent!(new)
  end

  test "a workspace losing its last tab gets a fresh pane" do
    {new, eff} = Reconcile.run(fresh(), %{})
    assert eff == [{:close, 1}, {:spawn, 2, %{cols: 74, rows: 23}}]
    assert [%{layout: l}] = ws(new).tabs
    assert Layout.pane_ids(l) == [2] and new.focus.pane == 2
    consistent!(new)
  end

  test "drops and adopts at once; adopted panes fill a workspace emptied by drops" do
    app = pfx(fresh(), "v")
    {new, eff} = Reconcile.run(app, live([1, 4]))
    assert eff == [{:close, 2}, {:adopt, 4}]
    assert new.focus.pane == 1
    consistent!(new)

    {new, eff} = Reconcile.run(fresh(), live([3]))
    assert eff == [{:close, 1}, {:adopt, 3}]
    assert [%{name: "scratch"}] = ws(new).tabs
    assert new.focus.pane == 3
    consistent!(new)
  end

  test "tabs made by reconcile take counter ids: a later new_tab never repeats one" do
    # restart recovery adopts pane 5 into a scratch tab, then the user opens a tab
    {app, _} = Reconcile.run(fresh(), live([1, 5]))
    {app, _} = Actions.new_tab(app)
    ids = Enum.map(ws(app).tabs, & &1.id)
    assert ids == Enum.uniq(ids) and length(ids) == 3

    # a workspace emptied by drops gets a fresh tab with a counter id too
    {app, _} = Reconcile.run(fresh(), live([]))
    {app, _} = Actions.new_tab(app)
    ids = Enum.map(ws(app).tabs, & &1.id)
    assert ids == Enum.uniq(ids) and 1 not in ids
  end
end
