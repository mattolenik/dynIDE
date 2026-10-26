defmodule DynideSceneHtmlTest do
  use ExUnit.Case, async: true

  alias DynideScene.{Fixture, Scene}
  alias DynideScene.Scene.Node

  @banned String.graphemes("─│┌┐└┘«»●○▸✓↵")

  defp roles(%Node{role: r, children: kids}), do: [r | Enum.flat_map(kids, &roles/1)]

  defp html(name), do: name |> Fixture.load() |> DynideSceneHtml.render() |> IO.iodata_to_binary()

  test "every fixture renders data-role for each chrome role, with no terminal glyphs" do
    for name <- Fixture.names() do
      out = html(name)
      scene = Fixture.load(name)

      for r <- scene.chrome |> roles() |> Enum.uniq() do
        assert out =~ ~s(data-role="#{r}"), "#{name}: missing role #{r}"
      end

      for g <- @banned, do: refute(out =~ g, "#{name}: contains #{g}")
    end
  end

  test "every chrome node type has a golden fixture" do
    seen = Fixture.names() |> Enum.flat_map(&roles(Fixture.load(&1).chrome)) |> MapSet.new()
    assert Scene.roles() -- MapSet.to_list(seen) == []
  end

  test "the popup golden fixture puts its pane after the chrome, labelled by its title" do
    out = html("popup_120x40")
    [_, after_chrome] = String.split(out, ~s(data-role="root"), parts: 2)
    assert after_chrome =~ ~s(<div class="pane focused popup" data-pane="3")
    assert after_chrome =~ "<b>lazygit</b>"
    assert out =~ "left:45ch;top:15.0em;width:56ch"
  end

  test "text is escaped and panes are labelled" do
    scene = %Scene{
      size: %{cols: 10, rows: 3},
      panes: [%Scene.Pane{id: 7, rect: %{x: 0, y: 0, w: 10, h: 2}, rows: {:ref, 7, 0}}],
      chrome: %Node{
        role: :root,
        id: :root,
        children: [%Node{role: :text, id: :t, text: "<b>&'\""}]
      }
    }

    out = scene |> DynideSceneHtml.render(theme: :light) |> IO.iodata_to_binary()
    assert out =~ "&lt;b&gt;&amp;&#39;&quot;"
    assert out =~ ~s(data-pane="7")
  end

  test "a zoomed tab's label gets a Z in front" do
    tab = %Node{role: :tab, id: {:tab, 1}, text: "1", props: %{index: 1, zoomed: true}}

    scene = %Scene{
      size: %{cols: 10, rows: 3},
      focus: %{pane: nil, chrome: nil},
      chrome: %Node{role: :root, id: :root, children: [tab]}
    }

    assert scene |> DynideSceneHtml.render() |> IO.iodata_to_binary() =~
             ~r/data-role="tab"[^>]*>Z 1</
  end

  test "an item's detail is a muted line after its children" do
    item = %Node{role: :item, id: {:workspace, 1}, props: %{detail: "main ↑1"}}

    scene = %Scene{
      size: %{cols: 10, rows: 3},
      focus: %{pane: nil, chrome: nil},
      chrome: %Node{role: :root, id: :root, children: [item]}
    }

    assert scene |> DynideSceneHtml.render() |> IO.iodata_to_binary() =~
             ~s(<span class="tok-muted">main ↑1</span></li>)
  end

  test "a nested rect is placed in scene cells, not offset by its parent's origin" do
    inner = %Node{role: :divider, id: :split, rect: %{x: 12, y: 7, w: 5, h: 1}}

    outer = %Node{
      role: :sidebar,
      id: :sidebar,
      rect: %{x: 10, y: 4, w: 20, h: 10},
      children: [inner]
    }

    scene = %Scene{
      size: %{cols: 40, rows: 20},
      focus: %{pane: nil, chrome: nil},
      chrome: %Node{role: :root, id: :root, children: [outer]}
    }

    out = scene |> DynideSceneHtml.render() |> IO.iodata_to_binary()
    # the sidebar box at its scene cell; the divider 2 cols, 3 rows inside it
    assert out =~ ~s(data-id=":sidebar" class="tok-default" data-rect style="left:10ch;top:6.0em;)
    assert out =~ ~s(data-id=":split" class="tok-default" data-rect style="left:2ch;top:4.5em;)
  end
end
