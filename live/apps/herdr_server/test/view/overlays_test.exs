defmodule HerdrServer.View.OverlaysTest do
  use ExUnit.Case, async: true

  import HerdrServer.ViewHelpers

  alias HerdrScene.Scene
  alias HerdrScene.Scene.Overlay
  alias HerdrServer.Client.{Pointer, Selection, State}
  alias HerdrServer.View
  alias HerdrServer.View.Overlays

  @rect %{x: 0, y: 0, w: 40, h: 10}

  defp client(pointer, facts),
    do: %State{size: %{cols: 80, rows: 24}, transport: :ref, pointer: pointer, facts: facts}

  defp selection(pane),
    do: %Pointer{
      selection: %Selection{pane: pane, anchor: {1, 10}, head: {3, 11}, unit: :char, shown: true}
    }

  defp facts(offset, scrolled),
    do: %{
      scrolled: scrolled,
      alt_screen: false,
      scroll: %{total: 100, viewport: 10, offset: offset}
    }

  test "no pointer state and no facts: no overlays" do
    assert Overlays.pane(1, @rect, client(%Pointer{}, %{})) == []
  end

  test "selection maps absolute rows through the facts offset, only on its pane" do
    c = client(selection(2), %{2 => facts(10, false)})

    assert [%Overlay{kind: :selection, args: %{from: {1, 0}, to: {3, 1}}}] =
             Overlays.pane(2, @rect, c)

    assert Overlays.pane(1, @rect, c) == []
  end

  test "scrolled pane gets a scrollbar first, then the selection" do
    c = client(selection(2), %{2 => facts(10, true)})

    assert [
             %Overlay{kind: :scrollbar, args: %{total: 100, viewport: 10, offset: 10}},
             %Overlay{kind: :selection}
           ] = Overlays.pane(2, @rect, c)
  end

  test "link hover only on its pane" do
    hover = %{pane: 1, id: 7, from: {2, 3}, to: {5, 3}}
    c = client(%Pointer{hover: hover}, %{})

    assert [%Overlay{kind: :link_hover, args: %{id: 7, from: {2, 3}, to: {5, 3}}}] =
             Overlays.pane(1, @rect, c)

    assert Overlays.pane(2, @rect, c) == []
  end

  test "View.compute output validates with overlays" do
    app = fresh(80, 24)

    c =
      client(%Pointer{hover: %{pane: 1, id: 0, from: {0, 0}, to: {2, 0}}}, %{1 => facts(5, true)})

    scene = View.compute(app, c)
    assert [%Overlay{kind: :scrollbar}, %Overlay{kind: :link_hover}] = hd(scene.panes).overlays
    assert :ok = Scene.validate(scene)
  end
end
