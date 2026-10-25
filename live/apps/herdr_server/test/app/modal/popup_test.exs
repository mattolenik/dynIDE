defmodule HerdrServer.App.Modal.PopupTest do
  use ExUnit.Case, async: true

  alias HerdrScene.{Event, Scene}
  alias HerdrServer.App.{Actions, Modal}
  alias HerdrServer.App.Modal.Popup
  alias HerdrServer.Client.State
  alias HerdrServer.View

  defp rect(x, y, w, h), do: %{x: x, y: y, w: w, h: h}

  # herdr's popup_size.rs tests
  describe "size/2 and parse/1" do
    test "parses cells and percent; rejects bad percents and bare strings" do
      assert Popup.parse(120) == {:ok, {:cells, 120}}
      assert Popup.parse("80%") == {:ok, {:percent, 80}}
      assert Popup.parse(nil) == {:ok, nil}

      for bad <- ["0%", "101%", "%", "120", "8x%", -1, 1.5],
          do: assert({:error, _} = Popup.parse(bad))
    end

    test "requested outer size and the inner terminal area" do
      spec = %{width: {:percent, 80}, height: {:percent, 40}}

      assert Popup.size(spec, rect(0, 0, 100, 30)) ==
               %{outer: rect(10, 9, 80, 12), inner: rect(11, 10, 77, 10)}
    end

    test "allows the full terminal as the outer size" do
      spec = %{width: {:percent, 100}, height: {:percent, 100}}

      assert Popup.size(spec, rect(4, 2, 100, 30)) ==
               %{outer: rect(4, 2, 100, 30), inner: rect(5, 3, 97, 28)}
    end

    test "enforces the minimum terminal width; too small an area is nil" do
      %{outer: o, inner: i} = Popup.size(%{width: {:cells, 4}, height: nil}, rect(0, 0, 80, 24))
      assert o.w == 6 and i.w == 4
      assert Popup.size(%{width: nil, height: nil}, rect(0, 0, 5, 24)) == nil
    end

    test "defaults to half the area, centred" do
      assert Popup.size(%{width: nil, height: nil}, rect(0, 0, 80, 24)).outer ==
               rect(20, 6, 40, 12)
    end
  end

  defp open do
    {app, _} = Actions.init(%{cols: 100, rows: 30})
    app = put_in(app.session.next_id, 9)
    {:ok, app, 9, size} = Popup.open(app, %{width: {:percent, 80}, height: nil})
    {app, size}
  end

  test "open pushes a capturing modal; a second open is refused" do
    {app, %{cols: c, rows: r}} = open()
    assert %{kind: :popup, pane: 9, capture: true, layout_gen: 0, owner: {1, 1}} = Modal.top(app)
    # the id is allocated
    assert app.session.next_id == 10
    assert Modal.capturing?(app.focus)
    [%{id: 9, rect: inner}] = Popup.rects(app)
    assert {inner.w, inner.h} == {c, r}
    assert Popup.open(app, %{}) == {:error, "popup already open"}
  end

  test "the popup closes once its owner tab is gone, not before" do
    {app, _} = open()
    assert Popup.orphaned(app) == {app, []}
    # another tab of the workspace is not the owner
    {app2, _} = Popup.close(app)
    {app2, _} = Actions.new_tab(app2)
    {:ok, app2, id, _} = Popup.open(app2, %{})
    {other, _} = Actions.switch_tab(app2, 1)
    assert Popup.orphaned(other) == {other, []}
    ws = hd(app2.session.workspaces)

    gone =
      put_in(app2.session.workspaces, [
        %{ws | tabs: Enum.reject(ws.tabs, &(&1.id == 2)), active_tab: 1}
      ])

    assert {closed, [{:close, ^id}]} = Popup.orphaned(gone)
    assert closed.focus.modal == []
  end

  test "keys (releases, Esc and prefix keys included) and pastes reach the popup pane" do
    {app, _} = open()

    for ev <- [Event.key("a"), Event.key(:escape), Event.key("b", [:ctrl])] do
      assert {^app, [{:key, 9, ^ev}]} = Actions.apply(app, ev)
    end

    release = {:key, %{key: "a", mods: [], event: :release}}
    assert {^app, [{:key, 9, ^release}]} = Actions.apply(app, release)
    assert {^app, [{:paste, 9, "hi"}]} = Actions.apply(app, {:paste, "hi"})
  end

  test "mouse inside the popup goes to it, pane-relative; outside is dropped" do
    {app, _} = open()
    [%{rect: r}] = Popup.rects(app)
    m = %{kind: :press, button: :left, x: r.x + 2, y: r.y + 1, mods: []}
    assert {^app, [{:mouse, 9, {:mouse, %{x: 2, y: 1}}}]} = Actions.apply(app, {:mouse, m})
    assert {^app, []} = Actions.apply(app, {:mouse, %{m | x: 0, y: 0}})
  end

  test "the popup pane's exit pops the modal and closes it; other exits do not" do
    {app, _} = open()
    {gone, fx} = Actions.apply(app, {:pane_exited, 9})
    assert gone.focus.modal == [] and fx == [{:close, 9}]
    assert Popup.exited(app, 1) == nil
  end

  test "close/1 closes the open popup; none open is a no-op" do
    {app, _} = open()
    {closed, [{:close, 9}]} = Popup.close(app)
    assert closed.focus.modal == []
    assert Popup.close(closed) == {closed, []}
  end

  test "the scene draws the popup last on the popup layer, focused, without chrome" do
    {app, _} = open()
    scene = View.compute(app, %State{size: %{cols: 100, rows: 30}})
    assert :ok = Scene.validate(scene)
    popup = List.last(scene.panes)
    assert %{id: 9, layer: :popup, rows: {:ref, 9, 0}, border: %{title: "popup"}} = popup
    assert Enum.all?(Enum.drop(scene.panes, -1), &(&1.layer == :base))
    assert scene.focus.pane == 9
    refute Enum.any?(scene.chrome.children, &(&1.role == :modal))
    assert popup.rows == {:ref, 9, 0}
    bumped = View.compute(Popup.bump(app, 9), %State{size: %{cols: 100, rows: 30}})
    assert List.last(bumped.panes).rows == {:ref, 9, 1}
  end
end
