defmodule DynideServer.Client.PaneSceneTest do
  use ExUnit.Case, async: true

  alias DynideScene.{Cell, Scene}
  alias DynideServer.Client.PaneScene

  defp row(cols), do: Cell.blank_row(cols)

  defp fetched(cols, rows, cursor),
    do: {7, List.to_tuple(for(_ <- 1..rows, do: row(cols))), cursor}

  @cursor %{x: 79, y: 23, shape: :block, visible: true}

  test "a client smaller than the pane clips it" do
    sc = PaneScene.build(3, fetched(80, 24, @cursor), %{cols: 40, rows: 10})
    assert Scene.validate(sc) == :ok
    assert [%{id: 3, rect: %{x: 0, y: 0, w: 40, h: 10}, rows: {:inline, rows}}] = sc.panes
    assert length(rows) == 10
    assert sc.focus.pane == 3
    # outside the clipped rect: no host cursor
    assert sc.cursor == nil
  end

  test "a client larger than the pane shows it whole with the host cursor" do
    sc = PaneScene.build(3, fetched(80, 24, %{@cursor | x: 5, y: 2}), %{cols: 120, rows: 40})
    assert Scene.validate(sc) == :ok
    assert [%{rect: %{w: 80, h: 24}, rows: {:inline, rows}}] = sc.panes
    assert length(rows) == 24
    assert sc.cursor == %{x: 5, y: 2, shape: :block}
    assert %Scene.Node{role: :root, children: []} = sc.chrome
  end

  test "no rows is an empty pane" do
    sc = PaneScene.build(3, nil, %{cols: 80, rows: 24})
    assert Scene.validate(sc) == :ok
    assert [%{rect: %{w: 0, h: 0}, rows: {:inline, []}}] = sc.panes
  end
end
