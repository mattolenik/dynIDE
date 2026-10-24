defmodule HerdrTerm.Client.Term.Render.Chrome.Modal do
  @moduledoc """
  The `:modal` and `:menu` regions (pure, inventory §5), drawn in the region rect the
  server placed, following `HerdrServer.View.Modal`'s layout convention:

    * Square border in `:accent` (`:error` for `tone: :danger`), panel and content on
      `:surface`. Content rows from the first inner row: texts with a leading blank
      (the title bold, or in its own token), an `:input` on inner row 2 at the earliest
      drawn from `props.offset`, then the `:actions` row (inner row 3 at the earliest,
      clamped to the last inner row) with its buttons centred, 2 blanks apart.
    * A button is `" <key> <label> "` (`↵` for Enter from the theme, `esc`, `^c` for
      ctrl+c, else the key's name); the primary one is `:selected` (on `:error` for a
      danger modal), the others `:surface` bold.
    * A menu is one `" label"` row per `:item`, the selected one `:selected`.
    * Panels under 4x4 (menus 4x3) have no room for their content: a blank `:surface`
      box.

  Hits, topmost first: buttons (`[id, :actions, button]`) or entries (`[id, entry]`),
  the panel (`[id]`), then the backdrop `[id, :backdrop]` over the whole screen, so a
  click anywhere outside the panel lands on it and nothing beneath gets one.
  """

  alias HerdrScene.Cell
  alias HerdrScene.Scene.Node
  alias HerdrTerm.Cells
  alias HerdrTerm.Client.Term.Render.Chrome
  alias HerdrTerm.Client.Term.Render.Chrome.Text
  alias HerdrTerm.Client.Term.Theme

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

    {lines, next} =
      Enum.reduce(body, {[], 0}, fn n, {acc, i} ->
        i = if n.role == :input, do: max(i, 2), else: i
        {[{i, line(n, w, theme)} | acc], i + 1}
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

        {Enum.reject([{ay, row} | lines], fn {i, _} -> i >= h end), hits}

      _ ->
        {Enum.reject(lines, fn {i, _} -> i >= h end), []}
    end
  end

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
