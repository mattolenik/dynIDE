defmodule DynideTerm.Client.Term.Render.Chrome.Modal do
  @moduledoc """
  The `:modal` and `:menu` regions (pure, inventory §5), drawn in the region rect the
  server placed, following `DynideServer.View.Modal`'s layout convention:

    * Square border in `:accent` (`:error` for `tone: :danger`), panel and content on
      `:surface`. Content rows from the first inner row: texts with a leading blank
      (the title bold, or in its own token), an `:input` on inner row 2 at the earliest
      drawn from `props.offset`, then the `:actions` row (inner row 3 at the earliest,
      clamped to the last inner row) with its buttons centred, 2 blanks apart.
    * Generic body pieces: a `:spacer` is `props.rows` blank rows; a `:group` one row of
      its inline texts and keycaps (keycaps bold `:accent`); a `:tabs` section row is
      `" label "` pills (the active one `:selected`, others `:muted`, 1 blank apart)
      over a `:muted` rule; a `:list` fills `props.rows` rows with bold headings
      (`:text`), choice items `" ▸ label ✓"` (cursor glyph when `selected`, check when
      `current`, the badge glyphs after the label for `props.indicators`) and shortcut
      items (their keycaps joined by `", "`, padded to the widest, then the label; muted
      for an `"unset"` text), the selected item on `:selected`.
    * A button is `" <key> <label> "` (`↵` for Enter from the theme, `esc`, `^c` for
      ctrl+c, else the key's name); the primary one is `:selected` (on `:error` for a
      danger modal), the others `:surface` bold.
    * A menu is one `" label"` row per `:item`, the selected one `:selected`.
    * Panels under 4x4 (menus 4x3) have no room for their content: a blank `:surface`
      box.

  Hits, topmost first: buttons (`[id, :actions, button]`), then section tabs
  (`[id, :sections, tab]`) and list items (`[id, :list, item]`), or menu entries
  (`[id, entry]`),
  the panel (`[id]`), then the backdrop `[id, :backdrop]` over the whole screen, so a
  click anywhere outside the panel lands on it and nothing beneath gets one.
  """

  alias DynideScene.Cell
  alias DynideScene.Scene.Node
  alias DynideTerm.Cells
  alias DynideTerm.Client.Term.Render.Chrome
  alias DynideTerm.Client.Term.Render.Chrome.Text
  alias DynideTerm.Client.Term.Theme

  @gap 2

  @spec render(Node.t(), Theme.t(), %{cols: non_neg_integer, rows: non_neg_integer}) ::
          {[{non_neg_integer, Chrome.seg()}], [Chrome.hit()]}
  def render(%Node{id: id, rect: r, role: role} = node, theme, %{cols: cols, rows: rows}) do
    backdrop = Chrome.hit(%{x: 0, y: 0, w: cols, h: rows}, [id, :backdrop], :backdrop)
    panel = Chrome.hit(r, [id], role)
    surface = Theme.style(theme, :surface)

    if r.w < 4 or r.h < if(role == :menu, do: 3, else: 4) do
      {for(y <- r.y..(r.y + r.h - 1)//1, do: {y, {r.x, r.w, Cells.blank(r.w, surface)}}),
       [panel, backdrop]}
    else
      {lines, hits} = content(node, theme, r)
      {box(r, lines, theme, node), hits ++ [panel, backdrop]}
    end
  end

  # inner rows as {row_index, cells} (inner width), plus hits in screen cells
  defp content(%Node{role: :menu, id: id, children: items}, theme, r) do
    w = r.w - 2

    items
    |> Enum.take(r.h - 2)
    |> Enum.with_index()
    |> Enum.map(fn {item, i} ->
      token = if Map.get(item.props, :selected), do: :selected, else: :surface

      row =
        Text.clip(Text.text(" " <> (item.text || ""), token, theme), w, Theme.style(theme, token))

      {{i, row}, Chrome.hit(%{x: r.x + 1, y: r.y + 1 + i, w: w, h: 1}, [id, item.id], :item)}
    end)
    |> Enum.unzip()
  end

  defp content(%Node{id: id, children: children, props: props}, theme, r) do
    {w, h} = {r.w - 2, r.h - 2}
    danger = Map.get(props, :tone) == :danger
    {actions, body} = Enum.split_with(children, &(&1.id == :actions))

    {lines, body_hits, next} =
      Enum.reduce(body, {[], [], 0}, fn n, {acc, hs, i} ->
        i = if n.role == :input, do: max(i, 2), else: i
        {rows, hits} = block(n, w, theme)

        hits =
          for {dy, path, x, hw, role} <- hits,
              i + dy < h,
              do:
                Chrome.hit(%{x: r.x + 1 + x, y: r.y + 1 + i + dy, w: hw, h: 1}, [id | path], role)

        rows = rows |> Enum.with_index(i) |> Enum.map(fn {cells, y} -> {y, cells} end)
        {Enum.reverse(rows, acc), hs ++ hits, i + length(rows)}
      end)

    case actions do
      [%Node{children: buttons}] ->
        ay = next |> max(3) |> min(h - 1)
        {row, hits} = buttons(buttons, w, theme, danger)

        hits =
          for {bid, x, bw} <- hits,
              do:
                Chrome.hit(
                  %{x: r.x + 1 + x, y: r.y + 1 + ay, w: bw, h: 1},
                  [id, :actions, bid],
                  :button
                )

        {Enum.reject([{ay, row} | lines], fn {i, _} -> i >= h end), hits ++ body_hits}

      _ ->
        {Enum.reject(lines, fn {i, _} -> i >= h end), body_hits}
    end
  end

  # a body child's rows (inner width) and its hits `{row, path, x, w, role}`
  defp block(%Node{role: :spacer, props: p}, w, theme),
    do: {List.duplicate(blank(w, theme), Map.get(p, :rows, 1)), []}

  defp block(%Node{role: :group, children: cs}, w, theme) do
    pieces = Enum.map(cs, &inline(&1, theme))
    {[Text.clip(Cells.concat([Cells.blank(1, surface(theme)) | pieces]), w, surface(theme))], []}
  end

  defp block(%Node{role: :tabs, children: tabs}, w, theme) do
    {pieces, hits, _} =
      Enum.reduce(tabs, {[], [], 0}, fn t, {ps, hs, x} ->
        token = if Map.get(t.props, :active), do: :selected, else: :muted

        style =
          if token == :selected,
            do: %{Theme.style(theme, :selected) | attrs: [:bold]},
            else: on_surface(theme, :muted)

        pill = Cells.text(" #{t.text} ", style)
        pw = Cell.cols(pill)
        gap = if ps == [], do: [], else: [Cells.blank(1, surface(theme))]
        x = if ps == [], do: x, else: x + 1
        hit = {0, [:sections, t.id], x, min(pw, max(w - x, 0)), :tab}
        {ps ++ gap ++ [pill], [hit | hs], x + pw}
      end)

    rule = Cells.repeat(Theme.glyphs(theme).rule, w, on_surface(theme, :muted))
    hits = hits |> Enum.reverse() |> Enum.filter(fn {_, _, _, hw, _} -> hw > 0 end)
    {[Text.clip(Cells.concat([Cell.blank_row(0) | pieces]), w, surface(theme)), rule], hits}
  end

  defp block(%Node{role: :list, children: cs, props: p}, w, theme) do
    n = Map.get(p, :rows, length(cs))
    shown = Enum.take(cs, n)
    kw = shown |> Enum.map(&String.length(keys_text(&1))) |> Enum.max(fn -> 0 end)

    rows = Enum.map(shown, &list_row(&1, w, kw, theme))
    pad = List.duplicate(blank(w, theme), n - length(rows))

    hits =
      for {%Node{role: :item, id: iid}, dy} <- Enum.with_index(shown),
          do: {dy, [:list, iid], 0, w, :item}

    {rows ++ pad, hits}
  end

  defp block(n, w, theme), do: {[line(n, w, theme)], []}

  defp list_row(%Node{role: :item, children: [_ | _]} = item, w, kw, theme) do
    sel = Map.get(item.props, :selected)
    base = if sel, do: %{Theme.style(theme, :selected) | attrs: [:bold]}, else: surface(theme)
    unset = Enum.all?(item.children, &(&1.role != :keycap))

    kstyle =
      if sel,
        do: base,
        else: %{on_surface(theme, if(unset, do: :muted, else: :accent)) | attrs: [:bold]}

    row =
      Cells.concat([
        Cells.text(" " <> String.pad_trailing(keys_text(item), kw) <> " ", kstyle),
        Cells.text(item.text || "", base)
      ])

    Text.clip(row, w, base)
  end

  defp list_row(%Node{role: :item, props: p} = item, w, _kw, theme) do
    g = Theme.glyphs(theme)
    sel = Map.get(p, :selected)
    style = if sel, do: %{Theme.style(theme, :selected) | attrs: [:bold]}, else: surface(theme)
    marker = if sel, do: g.cursor, else: " "
    check = if Map.get(p, :current), do: " " <> g.check, else: ""
    label = " #{marker} #{item.text}#{preview(p, g)}#{check}"
    Text.clip(Cells.text(label, style), w, style)
  end

  # a heading (or any other row)
  defp list_row(%Node{text: t, token: tok}, w, _kw, theme),
    do:
      Text.clip(
        Cells.text(" " <> (t || ""), %{on_surface(theme, tok) | attrs: [:bold]}),
        w,
        surface(theme)
      )

  @states [:blocked, :working, :done, :idle, :unknown]

  # the indicator style's badge glyphs after its label
  defp preview(%{indicators: style}, g) when style in [:dots, :symbols] do
    set = if style == :dots, do: g.state_dots, else: g.state_symbols
    "  " <> Enum.map_join(@states, " ", &Map.fetch!(set, &1))
  end

  defp preview(_props, _g), do: ""

  defp keys_text(%Node{role: :item, children: [_ | _] = cs}),
    do: Enum.map_join(cs, ", ", &(&1.text || ""))

  defp keys_text(_node), do: ""

  defp inline(%Node{role: :keycap, text: t}, theme),
    do: Cells.text(t || "", %{on_surface(theme, :accent) | attrs: [:bold]})

  defp inline(%Node{text: t, token: tok}, theme), do: Cells.text(t || "", on_surface(theme, tok))

  defp blank(w, theme), do: Cells.blank(w, surface(theme))
  defp surface(theme), do: Theme.style(theme, :surface)

  defp line(%Node{role: :input, text: t, props: p}, w, theme) do
    visible = String.slice(t || "", Map.get(p, :offset, 0)..-1//1)
    Text.clip(Text.text(" " <> visible, :surface, theme), w, Theme.style(theme, :surface))
  end

  defp line(%Node{id: :title, text: t, token: tok}, w, theme) do
    style = %{on_surface(theme, tok || :strong) | attrs: [:bold]}
    Text.clip(Cells.text(" " <> (t || ""), style), w, Theme.style(theme, :surface))
  end

  defp line(%Node{text: t, token: tok}, w, theme),
    do:
      Text.clip(
        Cells.text(" " <> (t || ""), on_surface(theme, tok)),
        w,
        Theme.style(theme, :surface)
      )

  # {row, [{id, x, w}]}: buttons centred in w
  defp buttons(buttons, w, theme, danger) do
    pieces = Enum.map(buttons, &{&1.id, button(&1, theme, danger)})

    total =
      Enum.sum(Enum.map(pieces, &Cell.cols(elem(&1, 1)))) + @gap * max(length(pieces) - 1, 0)

    x0 = max(div(w - total, 2), 0)
    surface = Theme.style(theme, :surface)

    {cells, hits, _} =
      Enum.reduce(pieces, {[Cells.blank(x0, surface)], [], x0}, fn {id, p}, {cs, hs, x} ->
        pw = Cell.cols(p)
        gap = if hs == [], do: [], else: [Cells.blank(@gap, surface)]
        x = if hs == [], do: x, else: x + @gap
        {cs ++ gap ++ [p], [{id, x, min(pw, max(w - x, 0))} | hs], x + pw}
      end)

    hits = hits |> Enum.reverse() |> Enum.filter(fn {_, _, bw} -> bw > 0 end)
    {Text.clip(Cells.concat(cells), w, surface), hits}
  end

  defp button(%Node{text: label, props: p}, theme, danger) do
    style =
      cond do
        Map.get(p, :primary) and danger ->
          %{Theme.style(theme, :selected) | bg: Theme.style(theme, :error).fg, attrs: [:bold]}

        Map.get(p, :primary) ->
          %{Theme.style(theme, :selected) | attrs: [:bold]}

        true ->
          %{Theme.style(theme, :surface) | attrs: [:bold]}
      end

    Cells.text(" #{key_label(p, theme)} #{label} ", style)
  end

  defp key_label(%{key: :enter}, theme), do: Theme.glyphs(theme).enter
  defp key_label(%{key: :escape}, _), do: "esc"
  defp key_label(%{key: k, mods: [:ctrl]}, _) when is_binary(k), do: "^" <> k
  defp key_label(%{key: k}, _), do: to_string(k)

  # the token's colours and attributes on the panel background
  defp on_surface(theme, token),
    do: %{Theme.style(theme, token) | bg: Theme.style(theme, :surface).bg}

  defp box(r, lines, theme, node) do
    token = if Map.get(node.props, :tone) == :danger, do: :error, else: :accent
    b = on_surface(theme, token)
    g = Theme.glyphs(theme)
    w = r.w - 2
    blank = Cells.blank(w, Theme.style(theme, :surface))
    by = Map.new(lines)
    v = Cells.text(g.v, b)

    top = Cells.concat([Cells.text(g.tl, b), Cells.repeat(g.h, w, b), Cells.text(g.tr, b)])
    bottom = Cells.concat([Cells.text(g.bl, b), Cells.repeat(g.h, w, b), Cells.text(g.br, b)])

    mid =
      for i <- 0..(r.h - 3)//1,
          do: {r.y + 1 + i, {r.x, r.w, Cells.concat([v, Map.get(by, i, blank), v])}}

    [{r.y, {r.x, r.w, top}}] ++ mid ++ [{r.y + r.h - 1, {r.x, r.w, bottom}}]
  end
end
