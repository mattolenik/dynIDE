defmodule DynideTerm.Client.Term.Render.GraphicsTest do
  use ExUnit.Case, async: true

  alias DynideScene.Scene
  alias DynideScene.Scene.{Overlay, Pane}
  alias DynideTerm.Cells
  alias DynideTerm.Client.Term.Render.Graphics
  alias DynideTerm.Client.Term.Theme

  @cell {10, 20}
  @chrome %{base: %{}, top: %{}, hits: [], dim: false}
  @rect %{x: 2, y: 1, w: 40, h: 20}
  @empty %{images: %{}, placements: MapSet.new()}

  defp g(over \\ []) do
    Map.merge(
      %{
        image: {7, 42},
        placement: 1,
        x: 3,
        y: 2,
        cols: 10,
        rows: 5,
        x_off: 0,
        y_off: 0,
        src: {0, 0, 0, 0},
        px: {0, 0},
        z: 0,
        size: {100, 100},
        format: :rgba,
        bytes: 40_000
      },
      Map.new(over)
    )
  end

  defp scene(panes), do: %Scene{size: %{cols: 80, rows: 24}, panes: panes}

  defp pane(graphics, over \\ []),
    do: struct(%Pane{id: 1, rect: @rect, rows: {:ref, 1, 0}, graphics: graphics}, over)

  defp place(graphics, chrome \\ @chrome, over \\ []),
    do: Graphics.place(scene([pane(graphics, over)]), chrome, @cell)

  defp img(data \\ "pixels"),
    do: %{format: :rgba, width: 100, height: 100, bytes: byte_size(data || ""), data: data}

  describe "place/3" do
    test "fully inside: one piece in screen cells, the whole source" do
      assert [p] = place([g()])

      assert %{key: {1, 7, 42}, placement: 1, piece: 0, x: 5, y: 3, cols: 10, rows: 5} = p
      assert %{src: {0, 0, 100, 100}, off: {0, 0}, z: 0} = p
    end

    test "offsets are kept on unclipped edges, dropped on clipped ones" do
      assert [%{off: {3, 4}}] = place([g(x_off: 3, y_off: 4)])
      assert [%{off: {3, 0}}] = place([g(x_off: 3, y_off: 4, y: -1)])
    end

    test "partly above the pane: the visible rows, src cropped by clip cells * cell_h scaled" do
      # 4 rows of 20px show 160 source px: 2 clipped rows are 80 source px
      assert [p] = place([g(y: -2, rows: 4, size: {100, 160})])
      assert %{y: 1, rows: 2, src: {0, 80, 100, 80}} = p
    end

    test "wider than the pane: cols clipped to the content rect" do
      assert [%{x: 37, cols: 5, src: {0, 0, 50, 100}}] = place([g(x: 35)])
    end

    test "outside the pane: nothing" do
      assert place([g(y: 20)]) == []
      assert place([g(x: 40)]) == []
      assert place([g(x: -10)]) == []
      assert place([g(y: -5)]) == []
    end

    test "an explicit rendered size scales the crop" do
      # 200px wide for 10 cols: one clipped col (10px) is 5 source px
      assert [%{cols: 9, src: {5, 0, 45, 50}}] =
               place([g(x: -1, px: {200, 200}, src: {0, 0, 0, 0})])
    end

    test "nil cell px or a dimming modal: nothing" do
      assert Graphics.place(scene([pane([g()])]), @chrome, nil) == []
      assert place([g()], %{@chrome | dim: true}) == []
    end

    test "a toast over the middle splits it into pieces that tile the source" do
      # placement covers screen x 5..14, y 3..7; the toast x 8..11, y 4..5
      seg = {8, 4, Cells.text("toas", Cells.style([]))}
      chrome = %{@chrome | top: %{4 => [seg], 5 => [seg]}}
      pieces = place([g(size: {97, 61})], chrome)

      assert length(pieces) > 1
      assert pieces |> Enum.map(& &1.piece) |> Enum.uniq() |> length() == length(pieces)

      cells =
        for p <- pieces, x <- p.x..(p.x + p.cols - 1), y <- p.y..(p.y + p.rows - 1), do: {x, y}

      hole = for x <- 8..11, y <- 4..5, do: {x, y}
      want = for x <- 5..14, y <- 3..7, {x, y} not in hole, do: {x, y}
      assert Enum.sort(cells) == Enum.sort(want)
      assert_tiles(pieces, {97, 61})
    end

    test "selection overlay rows occlude" do
      sel = %Overlay{kind: :selection, args: %{from: {0, 3}, to: {39, 3}}}
      pieces = place([g()], @chrome, overlays: [sel])
      rows = for p <- pieces, y <- p.y..(p.y + p.rows - 1), uniq: true, do: y
      assert Enum.sort(rows) == [3, 5, 6, 7]
    end

    test "the scrollbar column occludes" do
      bar = %Overlay{kind: :scrollbar, args: %{total: 100, viewport: 20, offset: 0}}
      assert [%{x: 37, cols: 4}] = place([g(x: 35)], @chrome, overlays: [bar])
    end

    test "a base placement under a popup is split around the popup's border rect" do
      # base placement covers screen x 5..14, y 3..7; the popup's border rect x 7..12, y 3..6
      popup =
        pane([],
          id: 2,
          layer: :popup,
          rect: %{x: 8, y: 4, w: 4, h: 2},
          border: %{rect: %{x: 7, y: 3, w: 6, h: 4}, edges: [], title: nil}
        )

      pieces = Graphics.place(scene([pane([g(size: {97, 61})]), popup]), @chrome, @cell)

      cells =
        for p <- pieces, x <- p.x..(p.x + p.cols - 1), y <- p.y..(p.y + p.rows - 1), do: {x, y}

      want = for x <- 5..14, y <- 3..7, x not in 7..12 or y == 7, do: {x, y}
      assert Enum.sort(cells) == Enum.sort(want)
      assert_tiles(pieces, {97, 61})
    end

    test "a popup's placement is not cropped by the base pane under it" do
      popup =
        pane([g(x: 0, y: 0, cols: 4, rows: 2)],
          id: 2,
          layer: :popup,
          rect: %{x: 8, y: 4, w: 4, h: 2}
        )

      base = pane([g(placement: 9, x: 30)])

      assert [%{key: {2, 7, 42}, x: 8, y: 4, cols: 4, rows: 2, src: {0, 0, 100, 100}}] =
               Graphics.place(scene([base, popup]), @chrome, @cell)
               |> Enum.filter(&(elem(&1.key, 0) == 2))
    end

    test "overlapping popups: the earlier one's placement is cropped by the later" do
      img = g(x: 0, y: 0, cols: 10, rows: 6)
      a = pane([img], id: 2, layer: :popup, rect: %{x: 20, y: 5, w: 10, h: 6})
      b = pane([img], id: 3, layer: :popup, rect: %{x: 25, y: 5, w: 10, h: 6})

      assert [%{key: {2, _, _}, x: 20, cols: 5, rows: 6}, %{key: {3, _, _}, x: 25, cols: 10}] =
               Graphics.place(scene([pane([]), a, b]), @chrome, @cell)
    end

    test "under a dimming modal base placements hide, popup placements stay" do
      popup =
        pane([g(x: 0, y: 0, cols: 4, rows: 2)],
          id: 2,
          layer: :popup,
          rect: %{x: 50, y: 4, w: 4, h: 2}
        )

      assert [%{key: {2, _, _}}] =
               Graphics.place(scene([pane([g()]), popup]), %{@chrome | dim: true}, @cell)
    end

    test "past the crop budget, occluded placements hide whole, others stay" do
      # holes on alternating columns of two rows: far more pieces than the budget
      top = %{2 => for(x <- 2..41//2, do: {x, 1, nil}), 3 => for(x <- 3..41//2, do: {x, 1, nil})}
      clear = g(placement: 2, y: 10, rows: 2, cols: 40, x: 0)
      busy = g(placement: 1, y: 0, rows: 5, cols: 40, x: 0)
      assert [%{placement: 2, piece: 0}] = place([busy, clear], %{@chrome | top: top})
    end
  end

  # neighbouring pieces share exact source edges; outer edges are the original's
  defp assert_tiles(pieces, size) do
    for a <- pieces, b <- pieces, a != b, do: assert_seam(a, b)
    for p <- pieces, do: assert_outer(p, size)
  end

  defp assert_seam(%{src: {ax, ay, aw, ah}} = a, %{src: {bx, by, _, _}} = b) do
    if a.x + a.cols == b.x and a.y == b.y, do: assert(ax + aw == bx)
    if a.y + a.rows == b.y and a.x == b.x, do: assert(ay + ah == by)
  end

  defp assert_outer(%{src: {sx, sy, sw, sh}} = p, {w, h}) do
    if p.x == 5, do: assert(sx == 0)
    if p.y == 3, do: assert(sy == 0)
    if p.x + p.cols == 15, do: assert(sx + sw == w)
    if p.y + p.rows == 8, do: assert(sy + sh == h)
  end

  describe "diff/4" do
    test "first call uploads then places; an identical call only places" do
      pieces = place([g()])
      images = %{{1, 7, 42} => img()}
      {ops, cache} = Graphics.diff(@empty, pieces, images, %{file?: false})

      assert [{:upload, %{id: id, data: "pixels", medium: :direct, width: 100}}, {:place, pl}] =
               ops

      assert %{id: ^id, x: 5, y: 3, cols: 10, rows: 5, src: {0, 0, 100, 100}, off: {0, 0}} = pl
      assert {[{:place, ^pl}], ^cache} = Graphics.diff(cache, pieces, images, %{file?: false})

      assert {[{:delete_placement, ^id, pid}, {:delete_image, ^id}], @empty} =
               Graphics.diff(cache, [], images, %{file?: false})

      assert pid == pl.placement
    end

    test "large images go through the file medium only when allowed" do
      pieces = place([g()])
      big = img(:binary.copy("x", 40_000))
      images = %{{1, 7, 42} => big}

      assert {[{:upload, %{medium: :file}} | _], _} =
               Graphics.diff(@empty, pieces, images, %{file?: true})

      assert {[{:upload, %{medium: :direct}} | _], _} =
               Graphics.diff(@empty, pieces, images, %{file?: false})
    end

    test "the same image id in two panes gets two host ids" do
      other = %{pane([g()]) | id: 2, rect: %{@rect | x: 50, w: 20}}
      pieces = Graphics.place(scene([pane([g()]), other]), @chrome, @cell)
      images = %{{1, 7, 42} => img(), {2, 7, 42} => img()}
      {ops, _} = Graphics.diff(@empty, pieces, images, %{file?: false})
      ids = for {:upload, %{id: id}} <- ops, do: id
      assert length(Enum.uniq(ids)) == 2
    end

    test "no data yet or withheld: no upload, no place" do
      pieces = place([g()])
      assert {[], @empty} = Graphics.diff(@empty, pieces, %{}, %{file?: false})

      assert {[], @empty} =
               Graphics.diff(@empty, pieces, %{{1, 7, 42} => img(nil)}, %{file?: false})
    end
  end

  test "labels: withheld images get one label in the first visible row" do
    withheld = %{{1, 7, 42} => img(nil)}
    pieces = place([g(y: -1, cols: 20)])
    assert Graphics.labels(pieces, withheld) == [{5, 1, "[image 100x100]"}]
    assert Graphics.labels(pieces, %{{1, 7, 42} => img()}) == []
    assert Graphics.labels(place([g(cols: 5)]), withheld) == [{5, 3, "[imag"}]
  end

  test "run/4 splices labels into the frame rows" do
    sc = scene([pane([g(y: 0, cols: 20)])])
    frame = for y <- 0..23, do: {y, Cells.text(String.duplicate(".", 80), Cells.style([]))}

    ctx = %{
      cell_px: @cell,
      cache: @empty,
      images: %{{1, 7, 42} => img(nil)},
      file?: false,
      theme: Theme.default()
    }

    {rows, [], @empty} = Graphics.run(frame, sc, @chrome, ctx)
    {1, row} = Enum.at(rows, 1)
    assert Cells.to_text(row) == "....." <> "[image 100x100]" <> String.duplicate(".", 60)
  end

  test "file_transport?/1: ghostty only, never over ssh or inside herdr" do
    assert Graphics.file_transport?(%{"TERM_PROGRAM" => "ghostty"})
    refute Graphics.file_transport?(%{})
    refute Graphics.file_transport?(%{"TERM_PROGRAM" => "iTerm.app"})
    refute Graphics.file_transport?(%{"TERM_PROGRAM" => "ghostty", "SSH_TTY" => "/dev/pts/1"})
    refute Graphics.file_transport?(%{"TERM_PROGRAM" => "ghostty", "HERDR_PANE_ID" => ""})
  end
end
