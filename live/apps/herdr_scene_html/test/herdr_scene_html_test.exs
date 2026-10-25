defmodule HerdrSceneHtmlTest do
  use ExUnit.Case, async: true

  alias HerdrScene.{Fixture, Scene}
  alias HerdrScene.Scene.Node

  @banned String.graphemes("─│┌┐└┘«»●○▸✓↵")

  defp roles(%Node{role: r, children: kids}), do: [r | Enum.flat_map(kids, &roles/1)]

  defp html(name), do: name |> Fixture.load() |> HerdrSceneHtml.render() |> IO.iodata_to_binary()

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

    out = scene |> HerdrSceneHtml.render(theme: :light) |> IO.iodata_to_binary()
    assert out =~ "&lt;b&gt;&amp;&#39;&quot;"
    assert out =~ ~s(data-pane="7")
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

    out = scene |> HerdrSceneHtml.render() |> IO.iodata_to_binary()
    # the sidebar box at its scene cell; the divider 2 cols, 3 rows inside it
    assert out =~ ~s(data-id=":sidebar" class="tok-default" data-rect style="left:10ch;top:6.0em;)
    assert out =~ ~s(data-id=":split" class="tok-default" data-rect style="left:2ch;top:4.5em;)
  end
end
