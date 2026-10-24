defmodule HerdrTerm.Client.Term.Render.ComposeTest do
  use ExUnit.Case, async: true

  alias HerdrScene.{Cell, Fixture}
  alias HerdrScene.Scene
  alias HerdrScene.Scene.{Node, Overlay, Pane}
  alias HerdrTerm.Cells
  alias HerdrTerm.Client.Term.Render.Compose
  alias HerdrTerm.Client.Term.Theme

  @theme Theme.default()
  @s Cells.style([])

  defp pane(id, x, overlays \\ []) do
    %Pane{
      id: id,
      rect: %{x: x + 1, y: 1, w: 18, h: 7},
      border: %{
        rect: %{x: x, y: 0, w: 20, h: 9},
        edges: [:top, :bottom, :left, :right],
        title: nil
      },
      rows: {:ref, id, 0},
      overlays: overlays
    }
  end

  defp scene(overlays \\ []) do
    status = %Node{
      role: :status,
      id: :status,
      rect: %{x: 0, y: 9, w: 40, h: 1},
      children: [
        %Node{role: :text, id: :mode, text: "TERMINAL", token: :accent},
        %Node{
          role: :tabs,
          id: :tabs,
          children: [
            %Node{role: :tab, id: {:tab, 1}, text: "shell", props: %{index: 1, active: true}}
          ]
        },
        %Node{role: :text, id: :title, text: "", token: :muted},
        %Node{role: :text, id: :hint, text: "ctrl+b", token: :muted}
      ]
    }

    %Scene{
      size: %{cols: 40, rows: 10},
      panes: [pane(1, 0, overlays), pane(2, 20)],
      chrome: %Node{role: :root, id: :root, children: [status]},
      focus: %{pane: 2, chrome: nil}
    }
  end

  defp rows, do: %{1 => {Cells.text("left", @s)}, 2 => [{0, Cells.text("right", @s)}]}

  defp texts(frame), do: Enum.map(frame, fn {_, b} -> Cells.to_text(b) end)
  defp cells(frame, y), do: frame |> Enum.at(y) |> elem(1) |> Cell.decode_row()

  test "composes the known scene exactly" do
    border = "│" <> String.duplicate(" ", 18) <> "│"
    pad = fn s -> "│" <> String.pad_trailing(s, 18) <> "│" end

    expected =
      ["┌" <> String.duplicate("─", 18) <> "┐" <> "┌" <> String.duplicate("─", 18) <> "┐"] ++
        [pad.("left") <> pad.("right")] ++
        List.duplicate(border <> border, 6) ++
        ["└" <> String.duplicate("─", 18) <> "┘" <> "└" <> String.duplicate("─", 18) <> "┘"] ++
        ["TERMINAL  1:shell " <> String.duplicate(" ", 16) <> "ctrl+b"]

    frame = Compose.frame(scene(), rows(), @theme)
    assert texts(frame) == expected
    assert Enum.map(frame, &elem(&1, 0)) == Enum.to_list(0..9)
    assert Enum.all?(frame, fn {_, b} -> Cell.cols(b) == 40 end)
  end

  test "focused border uses focus colour, other does not; status styles" do
    frame = Compose.frame(scene(), rows(), @theme)
    assert Enum.at(cells(frame, 0), 25).fg == {:palette, 2}
    assert Enum.at(cells(frame, 0), 5).fg == :default
    status = cells(frame, 9)
    assert Enum.at(status, 0).attrs == [:bold]
    assert Enum.at(status, 10).attrs == [:inverse]
    assert Enum.at(status, 35).attrs == [:faint]
  end

  test "selection overlay inverts the range" do
    sel = %Overlay{kind: :selection, args: %{from: {0, 0}, to: {2, 0}}}
    row = cells(Compose.frame(scene([sel]), rows(), @theme), 1)

    assert for(i <- 1..5, do: :inverse in Enum.at(row, i).attrs) == [
             true,
             true,
             true,
             false,
             false
           ]
  end

  test "dim, hover and multi-row selection" do
    dim = %Overlay{kind: :dim, args: %{reason: :inactive}}
    hover = %Overlay{kind: :link_hover, args: %{id: 1, from: {1, 0}, to: {1, 0}}}
    sel = %Overlay{kind: :selection, args: %{from: {16, 1}, to: {1, 2}}}
    frame = Compose.frame(scene([dim, hover, sel]), rows(), @theme)
    assert :faint in Enum.at(cells(frame, 3), 5).attrs
    assert Enum.at(cells(frame, 1), 2).underline == :single
    assert :inverse in Enum.at(cells(frame, 2), 17).attrs
    assert :inverse in Enum.at(cells(frame, 3), 1).attrs
    assert :inverse in Enum.at(cells(frame, 3), 2).attrs
    refute :inverse in Enum.at(cells(frame, 3), 3).attrs
  end

  test "wide rows clip, missing rows blank, straddling wide char blanks" do
    long = Cells.text(String.duplicate("x", 30), @s)
    wide = Cells.text(String.duplicate("a", 17) <> "日", @s)
    frame = Compose.frame(scene(), %{1 => [{0, long}, {1, wide}]}, @theme)
    [r0, r1, r2 | _] = texts(frame)
    assert String.slice(r0, 0, 20) == "┌" <> String.duplicate("─", 18) <> "┐"
    assert String.slice(r1, 0, 20) == "│" <> String.duplicate("x", 18) <> "│"
    assert String.slice(r2, 0, 20) == "│" <> String.duplicate("a", 17) <> " │"

    assert Enum.at(texts(frame), 3) |> String.slice(0, 20) ==
             "│" <> String.duplicate(" ", 18) <> "│"
  end

  test "border title and cursor" do
    sc = scene()
    [p1, p2] = sc.panes
    p1 = %{p1 | border: %{p1.border | title: "a-very-long-title-that-clips"}}

    [top | _] =
      texts(
        Compose.frame(%{sc | panes: [p1, p2], cursor: %{x: 3, y: 4, shape: :bar}}, %{}, @theme)
      )

    assert String.slice(top, 0, 20) == "┌a-very-long-title-┐"
    assert Compose.cursor(%{sc | cursor: %{x: 3, y: 4, shape: :bar}}, %{}) == {{3, 4}, :bar}
    assert Compose.cursor(sc, %{}) == nil
  end

  test "the focused pane's cached cursor is placed in its content rect" do
    sc = Fixture.load("two_pane_split_120x40")
    [p1 | _] = sc.panes
    sc = %{sc | focus: %{sc.focus | pane: p1.id}, cursor: %{x: 0, y: 0, shape: :bar}}
    r = p1.rect
    c = %{x: 2, y: 1, shape: :underline, visible: true}
    assert Compose.cursor(sc, %{p1.id => c}) == {{r.x + 2, r.y + 1}, :underline}
    # clamped into the rect, hidden or below the rect means no cursor
    assert Compose.cursor(sc, %{p1.id => %{c | x: 10_000}}) ==
             {{r.x + r.w - 1, r.y + 1}, :underline}

    assert Compose.cursor(sc, %{p1.id => %{c | visible: false}}) == nil
    assert Compose.cursor(sc, %{p1.id => %{c | y: r.h}}) == nil
    assert Compose.cursor(sc, %{p1.id => nil}) == nil
  end

  test "screen/4 is frame/3 and cursor/2 in one call" do
    sc = Fixture.load("two_pane_split_120x40")
    [p1 | _] = sc.panes
    cursors = %{p1.id => %{x: 2, y: 1, shape: :underline, visible: true}}
    theme = Theme.default()

    assert Compose.screen(sc, %{}, cursors, theme) ==
             {Compose.frame(sc, %{}, theme), Compose.cursor(sc, cursors)}
  end

  test "partial borders and status overflow" do
    sc = scene()

    p = %Pane{
      id: 1,
      rect: %{x: 0, y: 0, w: 10, h: 3},
      border: %{rect: %{x: 0, y: 0, w: 10, h: 3}, edges: [:right], title: nil},
      rows: {:ref, 1, 0}
    }

    long = %Node{role: :text, id: :t, text: String.duplicate("z", 60), token: :default}

    chrome = %Node{
      role: :root,
      children: [
        %Node{
          role: :status,
          rect: %{x: 0, y: 9, w: 40, h: 1},
          children: [long, %Node{role: :text, id: :hint, text: "H", token: :muted}]
        }
      ]
    }

    sc = %{sc | panes: [p], chrome: chrome, focus: %{pane: nil, chrome: nil}}
    frame = Compose.frame(sc, %{1 => {Cells.text("0123456789", @s)}}, @theme)
    assert hd(texts(frame)) |> String.slice(0, 11) == "012345678│ "
    assert List.last(texts(frame)) == String.duplicate("z", 39) <> "H"
  end

  test "golden fixtures compose to full-width rows" do
    for name <- HerdrScene.Fixture.names() do
      sc = HerdrScene.Fixture.load(name)
      assert :ok = Scene.validate(sc)
      frame = Compose.frame(sc, %{}, @theme)
      assert length(frame) == sc.size.rows
      assert Enum.all?(frame, fn {_, b} -> Cell.cols(b) == sc.size.cols end)
    end
  end

  test "a top-level tab bar draws on its own row, status tabs keep working" do
    frame = Compose.frame(Fixture.load("two_tabs_80x24"), %{}, @theme)
    top = hd(texts(frame))
    assert String.slice(top, 0, 26) == String.duplicate(" ", 26)
    assert String.slice(top, 26, 12) == " 1:1   2:2  "
    assert List.last(texts(frame)) =~ ~r/^TERMINAL /
  end

  test "zero rows yields no rows" do
    assert Compose.frame(%Scene{size: %{cols: 5, rows: 0}}, %{}, @theme) == []
  end

  test "inline pane rows are used when rows_by_pane has no entry" do
    pane = %Pane{
      id: 1,
      rect: %{x: 0, y: 0, w: 4, h: 1},
      rows: {:inline, [{0, Cells.text("hey", @s)}]}
    }

    scene = %Scene{size: %{cols: 4, rows: 1}, panes: [pane]}
    assert texts(Compose.frame(scene, %{}, @theme)) == ["hey "]
    assert texts(Compose.frame(scene, %{1 => %{0 => Cells.text("map", @s)}}, @theme)) == ["map "]
  end

  # 5x3 grid of bordered 20x10 panes over a status row, with titles, partial edges,
  # selection/dim/hover overlays, wide chars (some straddling the clip edge), overflow
  # clusters, too-long and missing rows, and every rows_by_pane shape.
  defp grid_scene do
    panes =
      for i <- 0..14 do
        {cx, cy} = {rem(i, 5) * 20, div(i, 5) * 10}
        edges = if rem(i, 4) == 3, do: [:top, :left], else: [:top, :bottom, :left, :right]

        overlays =
          case rem(i, 5) do
            0 -> [%Overlay{kind: :selection, args: %{from: {3, 1}, to: {5, 4}}}]
            1 -> [%Overlay{kind: :dim, args: %{reason: :inactive}}]
            2 -> [%Overlay{kind: :link_hover, args: %{id: 1, from: {0, 2}, to: {4, 2}}}]
            _ -> []
          end

        %Pane{
          id: i + 1,
          rect: %{x: cx + 1, y: cy + 1, w: 18, h: 8},
          border: %{
            rect: %{x: cx, y: cy, w: 20, h: 10},
            edges: edges,
            title: if(rem(i, 3) == 0, do: "pane #{i + 1} 日本語 title", else: nil)
          },
          rows:
            if(i == 14, do: {:inline, [{0, Cells.text("inline", @s)}]}, else: {:ref, i + 1, 0}),
          overlays: overlays
        }
      end

    %{scene() | size: %{cols: 100, rows: 31}, panes: panes}
    |> Map.update!(:chrome, fn root ->
      [status] = root.children
      %{root | children: [%{status | rect: %{x: 0, y: 30, w: 100, h: 1}}]}
    end)
  end

  defp grid_rows do
    bold = Cells.style(fg: {:rgb, 1, 2, 3}, attrs: [:bold])
    family = "👨‍👩‍👧‍👦"

    lines = [
      String.duplicate("abc", 10),
      String.duplicate("a", 17) <> "日本",
      "日本語のテキスト" <> family <> "x",
      family <> " " <> family,
      "plain"
    ]

    styles = Stream.cycle([@s, bold])

    for id <- 1..13, into: %{} do
      rows = Enum.zip_with(lines, styles, &Cells.text("#{id}#{&1}", &2))
      {id, rows_shape(rem(id, 3), rows)}
    end
  end

  defp rows_shape(0, rows), do: List.to_tuple(rows)
  defp rows_shape(1, rows), do: Enum.with_index(rows, fn r, n -> {n, r} end)
  defp rows_shape(2, rows), do: Map.new(rows_shape(1, rows))

  test "15-pane grid composes byte-identically to the reference frame" do
    frame = Compose.frame(grid_scene(), grid_rows(), @theme)
    assert Enum.all?(frame, fn {_, b} -> Cell.cols(b) == 100 end)
    digest = :crypto.hash(:sha256, Enum.map(frame, fn {y, b} -> [<<y::16>>, b] end))

    assert Base.encode16(digest, case: :lower) ==
             "877ee358451f2053cd8870aff7dcf1bfaf533c4df609e2e8826b3f1dd29b3540"
  end
end
