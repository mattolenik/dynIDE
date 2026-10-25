defmodule HerdrServer.Client.CopyModeTest.Reader do
  @moduledoc false
  # A fake `screen_rows`: `lines` is a tuple of text lines or `{text, :wrap}` (soft wrap).
  alias HerdrScene.Cell

  def rows(lines, first, last) do
    last = Enum.min([last, first + 999, tuple_size(lines) - 1])

    for y <- first..last//1 do
      {text, wrapped} =
        case elem(lines, y) do
          {t, :wrap} -> {t, true}
          t -> {t, false}
        end

      # Han characters are wide: the glyph cell and a width-0 tail
      cells = Enum.flat_map(String.graphemes(text), &cells/1)

      pad = List.duplicate(%Cell{}, max(80 - length(cells), 0))
      {y, Cell.encode_row(cells ++ pad), wrapped}
    end
  end

  # `rows/3` that tells `pid` the size of each read
  def logged(lines, pid, first, last) do
    send(pid, {:read, last - first + 1})
    rows(lines, first, last)
  end

  defp cells(g) do
    if g =~ ~r/\p{Han}/u,
      do: [%Cell{glyph: g, width: 2}, %Cell{glyph: "", width: 0}],
      else: [%Cell{glyph: g, width: 1}]
  end
end

defmodule HerdrServer.Client.CopyModeTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Event
  alias HerdrServer.Client.CopyMode
  alias HerdrServer.Client.CopyModeTest.Reader

  @id 7
  @h 24
  @w 80

  defp lines(overrides \\ %{}, n \\ 300) do
    0..(n - 1) |> Enum.map(&Map.get(overrides, &1, "line #{&1}")) |> List.to_tuple()
  end

  defp ctx(lines, offset \\ 276),
    do: %{
      scroll: %{total: tuple_size(lines), viewport: @h, offset: offset},
      h: @h,
      w: @w,
      read: {Reader, :rows, [lines]}
    }

  defp enter(ctx, cursor), do: CopyMode.enter(@id, Map.put(ctx, :cursor, cursor))

  defp keys(t, ctx, keys) do
    Enum.reduce(keys, {t, []}, fn
      k, {%CopyMode{} = t, _} -> CopyMode.key(t, key(k), ctx)
      _k, exited -> exited
    end)
  end

  defp key({k, mods}), do: Event.key(k, mods)
  defp key(k), do: Event.key(k)

  test "enter: at the visible cursor, else column 0 of the bottom viewport row" do
    c = ctx(lines())

    assert %CopyMode{pane: @id, cursor: {3, 299}, entry: :bottom, top: 276} =
             enter(c, {3, 23})

    assert %CopyMode{entry: 200} = enter(ctx(lines(), 200), nil)
    assert %CopyMode{cursor: {0, 299}} = enter(c, nil)
    assert %CopyMode{cursor: {0, 223}} = enter(ctx(lines(), 200), nil)
  end

  test "k x3 moves the cursor up 3 without scrolling" do
    c = ctx(lines())
    assert {%CopyMode{cursor: {3, 296}}, []} = keys(enter(c, {3, 23}), c, ~w(k k k))
  end

  test "h j l clamp; arrows move" do
    c = ctx(lines())
    t = enter(c, {0, 23})
    assert {%CopyMode{cursor: {0, 299}}, []} = keys(t, c, ["h", "j"])
    assert {%CopyMode{cursor: {1, 298}}, []} = keys(t, c, [:right, :up])
    assert {%CopyMode{cursor: {79, 299}}, []} = keys(enter(c, {79, 23}), c, ["l"])
  end

  test "g goes to row 0 and scrolls there; G back to the bottom" do
    c = ctx(lines())
    {t, actions} = keys(enter(c, {3, 23}), c, ["g"])
    assert %CopyMode{cursor: {3, 0}} = t
    assert actions == [{:scroll_top, @id, 0}]
    assert {%CopyMode{cursor: {3, 299}}, [{:scroll_top, @id, 276}]} = CopyMode.key(t, key("G"), c)
  end

  test "moving above the viewport scrolls to keep the cursor visible" do
    c = ctx(lines())
    {t, actions} = keys(enter(c, {0, 0}), c, ["k"])
    assert t.cursor == {0, 275}
    assert actions == [{:scroll_top, @id, 275}]
  end

  test "pages move the cursor and the viewport together" do
    c = ctx(lines(), 200)
    t = enter(c, {0, 10})
    assert {%CopyMode{cursor: {0, 188}}, [{:scroll_top, @id, 178}]} = keys(t, c, [{"b", [:ctrl]}])
    assert {%CopyMode{cursor: {0, 232}}, [{:scroll_top, @id, 222}]} = keys(t, c, [:page_down])
    assert {%CopyMode{cursor: {0, 198}}, [{:scroll_top, @id, 188}]} = keys(t, c, [{"u", [:ctrl]}])
    assert {%CopyMode{cursor: {0, 222}}, [{:scroll_top, @id, 212}]} = keys(t, c, [{"d", [:ctrl]}])
  end

  test "0 $ ^ go to the row's start, last character and first non-blank" do
    c = ctx(lines(%{299 => "   indented text"}))
    t = enter(c, {5, 23})
    assert {%CopyMode{cursor: {15, 299}}, []} = keys(t, c, ["$"])
    assert {%CopyMode{cursor: {15, 299}}, []} = keys(t, c, [{"$", [:shift]}])
    assert {%CopyMode{cursor: {0, 299}}, []} = keys(t, c, ["0"])
    assert {%CopyMode{cursor: {3, 299}}, []} = keys(t, c, ["^"])
    assert {%CopyMode{cursor: {0, 299}}, []} = keys(t, c, [:home])
  end

  test "w from \"foo bar\" col 0 goes to col 4" do
    c = ctx(lines(%{299 => "foo bar"}))
    assert {%CopyMode{cursor: {4, 299}}, []} = keys(enter(c, {0, 23}), c, ["w"])
  end

  test "word classes: separators are their own words; W B E only split on whitespace" do
    c = ctx(lines(%{299 => "foo.bar baz-qux"}))
    t = enter(c, {0, 23})
    assert {%CopyMode{cursor: {3, 299}}, _} = keys(t, c, ["w"])
    assert {%CopyMode{cursor: {4, 299}}, _} = keys(t, c, ["w", "w"])
    assert {%CopyMode{cursor: {8, 299}}, _} = keys(t, c, ["W"])
    assert {%CopyMode{cursor: {2, 299}}, _} = keys(t, c, ["e"])
    assert {%CopyMode{cursor: {6, 299}}, _} = keys(t, c, ["E"])
    t = enter(c, {14, 23})
    assert {%CopyMode{cursor: {12, 299}}, _} = keys(t, c, ["b"])
    assert {%CopyMode{cursor: {8, 299}}, _} = keys(t, c, ["B"])
  end

  test "word motions cross rows; a soft wrap joins the word" do
    wrapped = String.duplicate(" ", 77) <> "spl"
    c = ctx(lines(%{297 => "alpha", 298 => {wrapped, :wrap}, 299 => "it end"}))
    # end of row 297 is a line break: w lands on the next row's word
    assert {%CopyMode{cursor: {77, 298}}, _} = keys(enter(c, {0, 21}), c, ["w"])
    # "spl" + "it" is one word across the wrap
    assert {%CopyMode{cursor: {1, 299}}, _} = keys(enter(c, {77, 22}), c, ["e"])
    assert {%CopyMode{cursor: {77, 298}}, _} = keys(enter(c, {1, 23}), c, ["b"])
  end

  test "{ and } go to the nearest blank row and keep the column" do
    c = ctx(lines(%{290 => "", 295 => ""}))
    t = enter(c, {2, 21})
    assert {%CopyMode{cursor: {2, 295}}, _} = keys(t, c, ["{"])
    assert {%CopyMode{cursor: {2, 290}}, _} = keys(t, c, ["{", "{"])
    assert {%CopyMode{cursor: {2, 299}}, _} = keys(t, c, ["}"])
  end

  test "{ and } read in windows of at most 200 rows and stop at 1000" do
    n = 2600
    l = lines(%{1699 => "", 599 => ""}, n)
    c = %{ctx(l, n - @h) | read: {Reader, :logged, [l, self()]}}
    t = enter(c, {2, @h - 1})
    assert {%CopyMode{cursor: {2, 1699}}, _} = keys(t, c, ["{"])
    # the next blank is 1100 rows up: past the 1000-row limit
    assert {%CopyMode{cursor: {2, 1699}}, _} = keys(t, c, ["{", "{"])
    sizes = collect_reads([])
    assert sizes != [] and Enum.max(sizes) <= 200, inspect(sizes)
  end

  defp collect_reads(acc) do
    receive do
      {:read, n} -> collect_reads([n | acc])
    after
      0 -> acc
    end
  end

  test "v l l y copies the char selection and exits back to the entry offset" do
    c = ctx(lines(), 200)
    r = 210

    assert {:exit, [{:copy, @id, {0, ^r}, {2, ^r}}, {:scroll_top, @id, 200}]} =
             keys(enter(c, {0, 10}), c, ["v", "l", "l", "y"])
  end

  test "V selects whole lines; v again re-anchors; Enter copies" do
    c = ctx(lines(), 200)
    t = enter(c, {3, 10})

    assert {:exit, [{:copy, @id, {0, 210}, {79, 211}} | _]} =
             keys(t, c, ["V", "j", :enter])

    assert {:exit, [{:copy, @id, {5, 210}, {6, 210}} | _]} =
             keys(t, c, ["v", "l", "l", "v", "l", "y"])
  end

  test "space starts a selection; the selection overlay follows the cursor" do
    c = ctx(lines(), 200)
    {t, _} = keys(enter(c, {0, 10}), c, [" ", "l"])
    overlays = CopyMode.overlays(t, 200, @w, @h)

    assert Enum.any?(
             overlays,
             &match?(%{kind: :selection, args: %{from: {0, 10}, to: {1, 10}}}, &1)
           )

    assert Enum.any?(overlays, &match?(%{kind: :copy_cursor, args: %{at: {1, 10}}}, &1))
    assert CopyMode.overlays(t, 250, @w, @h) == []
  end

  test "exit at the bottom restores the bottom" do
    c = ctx(lines())
    assert {:exit, [{:scroll_bottom, @id}]} = keys(enter(c, nil), c, ["q"])
  end

  test "/bar Enter finds the next row containing bar; n N repeat and reverse" do
    c = ctx(lines(%{205 => "foo bar", 212 => "x bar bar"}), 200)
    t = enter(c, {0, 0})
    {t, []} = keys(t, c, ["/", "b", "a"])
    assert t.prompt == %{dir: :forward, query: "ba"}
    assert CopyMode.label(t) == "/ba"

    {t, []} = keys(t, c, ["r", :enter])
    assert t.prompt == nil
    assert t.cursor == {4, 205}
    assert t.match == {{4, 205}, {6, 205}}

    overlays = CopyMode.overlays(t, 200, @w, @h)

    assert Enum.any?(
             overlays,
             &match?(%{kind: :search_match, args: %{from: {4, 5}, to: {6, 5}, current: true}}, &1)
           )

    assert Enum.any?(
             overlays,
             &match?(
               %{kind: :search_match, args: %{from: {2, 12}, to: {4, 12}, current: false}},
               &1
             )
           )

    {t, []} = keys(t, c, ["n"])
    assert t.cursor == {2, 212}
    {t, []} = keys(t, c, ["n"])
    assert t.cursor == {6, 212}
    {t, []} = keys(t, c, ["N"])
    assert t.cursor == {2, 212}
  end

  test "? searches backward; smart case; y copies the current match" do
    c = ctx(lines(%{205 => "Foo", 210 => "foo"}), 200)
    t = enter(c, {0, 23})
    {t, _} = keys(t, c, ["?", "f", "o", "o", :enter])
    assert t.cursor == {0, 210}
    {t2, _} = keys(t, c, ["?", "F", "o", "o", :enter])
    assert t2.cursor == {0, 205}
    assert {:exit, [{:copy, @id, {0, 205}, {2, 205}} | _]} = keys(t2, c, ["y"])
  end

  test "a missing pattern leaves the cursor and gives a notice" do
    c = ctx(lines(), 200)
    t = enter(c, {0, 0})

    assert {%CopyMode{cursor: {0, 200}, match: nil}, [{:notice, %{text: text}}]} =
             keys(t, c, ["/", "z", "z", :enter])

    assert text =~ "zz"
  end

  test "the prompt: backspace edits, Esc closes it, the query is capped" do
    c = ctx(lines())
    {t, _} = keys(enter(c, nil), c, ["/", "a", "b", :backspace])
    assert t.prompt.query == "a"
    {t, _} = keys(t, c, [:escape])
    assert t.prompt == nil
    assert %CopyMode{} = t

    long = %{enter(c, nil) | prompt: %{dir: :forward, query: String.duplicate("a", 4096)}}
    assert {%{prompt: %{query: q}}, _} = CopyMode.key(long, key("b"), c)
    assert byte_size(q) == 4096
  end

  test "Esc clears the selection and search first, then exits" do
    c = ctx(lines(%{299 => "bar"}), 200)
    {t, _} = keys(enter(c, nil), c, ["v", "/", "b", :enter])
    assert t.anchor != nil and t.match != nil
    {t, []} = CopyMode.key(t, key(:escape), c)
    assert t.anchor == nil and t.match == nil and t.search == nil
    assert {:exit, [{:scroll_top, @id, 200}]} = CopyMode.key(t, key(:escape), c)
  end

  test "Esc Esc exits; unknown keys and releases change nothing" do
    c = ctx(lines())
    t = enter(c, nil)
    assert {^t, []} = CopyMode.key(t, key("z"), c)
    assert {^t, []} = CopyMode.key(t, Event.key("j", [], event: :release), c)
    assert {:exit, [{:scroll_bottom, @id}]} = keys(t, c, [:escape, :escape])
  end

  test "label: COPY, or the open prompt" do
    c = ctx(lines())
    assert CopyMode.label(enter(c, nil)) == nil
    {t, _} = keys(enter(c, nil), c, ["?", "x"])
    assert CopyMode.label(t) == "?x"
  end

  describe "the live viewport is authoritative" do
    test "output moved the viewport: a motion scrolls the cursor back into view" do
      t = enter(ctx(lines()), nil)
      assert t.cursor == {0, 299}
      # 30 more rows arrived and the bottom-following viewport moved to 306
      moved = ctx(lines(%{}, 330), 306)

      assert {%CopyMode{cursor: {0, 298}, top: 298}, [{:scroll_top, @id, 298}]} =
               CopyMode.key(t, key("k"), moved)
    end

    test "an own scroll request not landed yet is not undone" do
      c = ctx(lines())
      {t, [{:scroll_top, @id, 0}]} = CopyMode.key(enter(c, nil), key("g"), c)
      # the live offset still says 276: the cursor stays at the top without a new scroll
      assert {%CopyMode{cursor: {0, 1}, top: 0}, []} = CopyMode.key(t, key("j"), c)
    end

    test "visible matches are read from the live viewport rows" do
      t = %{enter(ctx(lines()), nil) | search: %{dir: :forward, query: "bar"}}
      moved = ctx(lines(%{305 => "bar"}, 310), 286)
      {t, []} = CopyMode.key(t, key("l"), moved)
      assert t.matches == [{{0, 305}, {2, 305}}]
    end
  end

  test "w with the cursor beyond a short last row stays put" do
    c = %{ctx(lines(%{299 => {"abc", :wrap}})) | w: 100}
    t = enter(c, {95, 23})
    assert {%CopyMode{cursor: {95, 299}}, []} = CopyMode.key(t, key("w"), c)
  end

  test "a match after a wide character spans its display columns" do
    c = ctx(lines(%{210 => "中x 中文"}), 200)
    {t, _} = keys(enter(c, {0, 0}), c, ["/", "x", :enter])
    assert t.match == {{2, 210}, {2, 210}}
    {t, _} = keys(t, c, ["/", "中", "文", :enter])
    assert t.match == {{4, 210}, {7, 210}}
  end

  test "search reads at most 20_000 rows from the cursor" do
    far = lines(%{20_050 => "needle"}, 20_100)
    c = %{ctx(far, 0) | scroll: %{total: 20_100, viewport: @h, offset: 0}}

    assert {%CopyMode{match: nil}, [{:notice, _}]} =
             keys(enter(c, {0, 0}), c, ["/", "n", "e", "e", "d", "l", "e", :enter])

    near = lines(%{19_999 => "needle"}, 20_100)
    c = %{c | read: {Reader, :rows, [near]}}

    assert {%CopyMode{match: {{0, 19_999}, _}}, _} =
             keys(enter(c, {0, 0}), c, ["/", "n", "e", "e", "d", "l", "e", :enter])
  end

  describe "wrap-around" do
    @wrapped [{:notice, %{level: :info, text: "search wrapped"}}]

    test "/ finds a match above the cursor after wrapping, with a notice" do
      c = ctx(lines(%{10 => "zebra"}), 200)
      {t, n} = keys(enter(c, {0, 23}), c, ["/", "z", "e", "b", "r", "a", :enter])
      assert t.cursor == {0, 10}
      assert hd(@wrapped) in n
    end

    test "? finds a match below the cursor after wrapping" do
      c = ctx(lines(%{250 => "zebra"}), 200)
      {t, n} = keys(enter(c, {0, 0}), c, ["?", "z", "e", "b", "r", "a", :enter])
      assert t.cursor == {0, 250}
      assert hd(@wrapped) in n
    end

    test "a total miss does not loop and keeps the no-match notice" do
      c = ctx(lines(), 200)

      for k <- ["/", "?"] do
        assert {%CopyMode{match: nil}, [{:notice, %{text: "no match for zz"}}]} =
                 keys(enter(c, {0, 0}), c, [k, "z", "z", :enter])
      end
    end

    test "n and N wrap, and a lone match wraps onto itself" do
      c = ctx(lines(%{10 => "zebra", 100 => "zebra"}), 200)
      t = %{enter(c, {0, 0}) | search: %{dir: :forward, query: "zebra"}}
      assert {%{cursor: {0, 10}}, n} = keys(t, c, ["n"])
      assert hd(@wrapped) in n

      t = %{t | cursor: {0, 10}, match: {{0, 10}, {4, 10}}}
      assert {%{cursor: {0, 100}}, n} = keys(t, c, ["N"])
      assert hd(@wrapped) in n

      one = ctx(lines(%{100 => "zebra"}), 200)
      t = %{enter(one, {0, 0}) | search: %{dir: :forward, query: "zebra"}}
      assert {%{cursor: {0, 100}}, n} = keys(t, one, ["n"])
      assert hd(@wrapped) in n
    end

    test "the wrapped leg shares the 20_000-row budget" do
      big = lines(%{150 => "needle"}, 20_100)
      c = %{ctx(big, 0) | scroll: %{total: 20_100, viewport: @h, offset: 0}}
      q = ["/", "n", "e", "e", "d", "l", "e", :enter]

      # cursor 20_000: forward covers 100 rows, the wrap has 19_900 rows and reaches 150
      assert {%{cursor: {0, 150}}, n} = keys(enter(c, {0, 20_000}), c, q)
      assert hd(@wrapped) in n

      # cursor 20_099: forward 1 row, wrap 19_999 rows (0..19_998)
      far = %{c | read: {Reader, :rows, [lines(%{19_950 => "needle"}, 20_100)]}}
      assert {%{cursor: {0, 19_950}}, n} = keys(enter(far, {0, 20_099}), far, q)
      assert hd(@wrapped) in n

      past = %{c | read: {Reader, :rows, [lines(%{19_999 => "needle"}, 20_100)]}}

      assert {%{match: nil}, [{:notice, %{text: "no match for needle"}}]} =
               keys(enter(past, {0, 20_099}), past, q)
    end
  end
end
