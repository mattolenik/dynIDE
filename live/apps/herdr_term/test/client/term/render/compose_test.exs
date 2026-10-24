defmodule HerdrTerm.Client.Term.Render.ComposeTest do
  use ExUnit.Case, async: true

  alias HerdrScene.{Cell, Fixture}
  alias HerdrScene.Scene
  alias HerdrScene.Scene.{Node, Overlay, Pane}
  alias HerdrTerm.Cells
  alias HerdrTerm.Client.Term.Render.{Chrome, Compose}
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
        ["TERMINAL" <> String.duplicate(" ", 26) <> "ctrl+b"]

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

  test "with chrome focus (an open prompt), the scene cursor wins over the pane's" do
    sc = Fixture.load("modal_prompt_80x24")
    c = %{x: 2, y: 1, shape: :underline, visible: true}
    assert sc.focus.chrome == [{:modal, 1}, :input]
    assert Compose.cursor(sc, %{sc.focus.pane => c}) == {{sc.cursor.x, sc.cursor.y}, :bar}
    # chrome focus without a scene cursor (a tiny prompt) keeps the pane's
    assert {{_, _}, :underline} = Compose.cursor(%{sc | cursor: nil}, %{sc.focus.pane => c})
  end

  test "cursor shapes map to blit shapes: :default stays, blinking picks *_blink" do
    sc = scene()
    p1 = hd(sc.panes)
    sc = %{sc | focus: %{sc.focus | pane: p1.id}}
    c = %{x: 0, y: 0, visible: true}

    for {shape, blink, want} <- [
          {:default, false, :default},
          {:default, true, :default},
          {:block, false, :block},
          {:block, true, :block_blink},
          {:underline, true, :underline_blink},
          {:bar, false, :bar},
          {:bar, true, :bar_blink}
        ] do
      assert {_, ^want} =
               Compose.cursor(sc, %{p1.id => Map.merge(c, %{shape: shape, blinking: blink})})
    end

    # inline scenes carry the cursor themselves, blinking optional
    inline = %{scene() | cursor: %{x: 1, y: 1, shape: :bar, blinking: true}}
    assert Compose.cursor(inline, %{}) == {{1, 1}, :bar_blink}
  end

  test "scrollbar draws on the content's last column; focus picks the thumb glyph" do
    bar = %Overlay{kind: :scrollbar, args: %{total: 70, viewport: 7, offset: 0}}
    sc = scene([bar])
    # pane 1 content is x 1..18, y 1..7; thumb len 1 at the top
    glyph = fn sc, y -> Enum.at(cells(Compose.frame(sc, rows(), @theme), y), 18).glyph end
    assert glyph.(sc, 1) == "▕"
    assert glyph.(sc, 2) == "▕"
    assert glyph.(%{sc | focus: %{sc.focus | pane: 1}}, 1) == "▐"
    assert Enum.at(cells(Compose.frame(sc, rows(), @theme), 1), 19).glyph == "│"
  end

  test "selection uses the host colours when the theme knows them" do
    sel = %Overlay{kind: :selection, args: %{from: {0, 0}, to: {0, 0}}}
    theme = %{@theme | host: %{fg: nil, bg: {0, 0, 0}}}

    assert Enum.at(cells(Compose.frame(scene([sel]), rows(), theme), 1), 1).bg ==
             {:rgb, 71, 71, 71}
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

  test "a top-level tab bar draws on its own row" do
    frame = Compose.frame(Fixture.load("two_tabs_80x24"), %{}, @theme)
    top = hd(texts(frame))
    # the sidebar's header row, then the tab bar
    assert String.slice(top, 0, 26) == " spaces" <> String.duplicate(" ", 18) <> "│"
    assert String.slice(top, 26, 20) == "   1    " <> " " <> "   2    " <> " + "
    assert List.last(texts(frame)) =~ ~r/^TERMINAL /
  end

  test "frame/4 and screen/5 with a precomputed chrome layout equal frame/3 and screen/4" do
    for name <- Fixture.names() do
      sc = Fixture.load(name)
      layout = Chrome.layout(sc.chrome, sc.size, @theme)
      assert Compose.frame(sc, %{}, @theme, layout) == Compose.frame(sc, %{}, @theme)
      assert Compose.screen(sc, %{}, %{}, @theme, layout) == Compose.screen(sc, %{}, %{}, @theme)
    end
  end

  defp with_modal(sc, props) do
    modal = %Node{role: :modal, id: {:modal, 0}, rect: %{x: 5, y: 2, w: 10, h: 3}, props: props}
    %{sc | chrome: %{sc.chrome | children: sc.chrome.children ++ [modal]}}
  end

  test "top-layer regions are spliced over panes and chrome" do
    full = %{1 => Tuple.duplicate(Cells.text(String.duplicate("x", 18), @s), 7)}
    frame = Compose.frame(with_modal(scene(), %{kind: :confirm}), full, @theme)
    assert Enum.all?(frame, fn {_, b} -> Cell.cols(b) == 40 end)
    # the modal box blanks its rect (x 5..14, rows 2..4) over pane 1's content
    for y <- 2..4 do
      assert String.slice(Enum.at(texts(frame), y), 0, 20) ==
               "│xxxx" <> String.duplicate(" ", 10) <> "xxxx│"
    end

    assert String.slice(Enum.at(texts(frame), 1), 0, 20) ==
             "│" <> String.duplicate("x", 18) <> "│"
  end

  test "a dimming modal fades every cell outside the top layer" do
    sc = with_modal(scene(), %{kind: :confirm, dim: true})
    frame = Compose.frame(sc, rows(), @theme)
    # rows without a top segment: every cell faint
    for y <- [0, 1, 9], c <- cells(frame, y), do: assert(:faint in c.attrs)
    # a row with the modal: faint outside, the box itself untouched
    row = cells(frame, 3)
    assert :faint in Enum.at(row, 4).attrs
    assert :faint in Enum.at(row, 15).attrs
    refute :faint in Enum.at(row, 5).attrs
    refute :faint in Enum.at(row, 14).attrs
    # status bold stays and gains faint
    assert Enum.at(cells(frame, 9), 0).attrs -- [:bold, :faint] == []
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

    # pane rows (0..29) unchanged since M7; the status row follows the chrome rasterizer
    panes = :crypto.hash(:sha256, Enum.map(Enum.take(frame, 30), fn {y, b} -> [<<y::16>>, b] end))

    assert Base.encode16(panes, case: :lower) ==
             "d2317d73ca6a68e081753d6c242d10d43a8c5437e5f6f8afc693d074ead9da63"

    assert Base.encode16(digest, case: :lower) ==
             "f8ae1a4440151a0d996835a2dedc01f825e92adea18d8a87313185afd905f521"
  end

  defp chrome_roles(nil), do: []

  defp chrome_roles(%Node{role: r, children: ch}),
    do: [r | Enum.flat_map(ch || [], &chrome_roles/1)]

  test "every role is covered by a fixture" do
    fixtures = Enum.map(Fixture.names(), &{&1, Fixture.load(&1)})

    roles = fixtures |> Enum.flat_map(fn {_, sc} -> chrome_roles(sc.chrome) end) |> Enum.uniq()
    assert Enum.sort(roles) == Enum.sort(Scene.roles())

    for {name, sc} <- fixtures do
      theme = Theme.for_scene(sc.chrome && sc.chrome.props[:theme], :dark)
      frame = Compose.frame(sc, %{}, theme)
      assert length(frame) == sc.size.rows, name
      assert Enum.all?(frame, fn {_, r} -> Cell.cols(r) == sc.size.cols end), name
    end
  end
end
