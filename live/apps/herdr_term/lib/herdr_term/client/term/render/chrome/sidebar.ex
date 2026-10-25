defmodule HerdrTerm.Client.Term.Render.Chrome.Sidebar do
  @moduledoc """
  The sidebar region (pure, inventory §2). The right column is the `│` edge (`:muted`,
  the `[:sidebar, :edge]` drag hit); the rest is the content width.

  Expanded: the spaces section (header `" spaces"` muted and bold, a blank row, one row
  per workspace line, the footer `" new"` left and `"menu"` right on its last row), then
  from the `:split` divider's row the agents section (a `─` rule, the drag hit, header
  `" agents"`, the agent items). `«` sits at (right-2, bottom-1).

  Collapsed: one row per workspace (index padded to 2, then its badge), a `─` rule, one
  badge row per agent when the sidebar has at least 7 rows, `»` bottom-centre.

  Item lines: line 0 indented 1, later lines 3, then an item's `:detail` (`:muted`,
  indented 3) when it has one and its rows fit; tokens joined by `" · "` (`:muted`), a
  single space after a badge; empty values drop; a line that does not fit ends in `…`.
  The active workspace row has the `:selected` background. Badges are `state_dots` or
  `state_symbols` (root `indicators`) in their state's colour.

  Workspace items are `drag: true` hits (reorder). A `drop_marker` draws the accent `▔`
  in column 0 of the item's first row (`:before`) or of the row below it (`:after`).

  Hits, topmost first: toggle, edge, split, every item, the buttons, the sections, then
  the region; all clipped to the region.
  """

  alias HerdrScene.Cell
  alias HerdrScene.Scene.Node
  alias HerdrTerm.Cells
  alias HerdrTerm.Client.Term.Render.Chrome
  alias HerdrTerm.Client.Term.Render.Chrome.Text
  alias HerdrTerm.Client.Term.Theme

  @state_tokens %{
    blocked: :error,
    done: :info,
    working: :warning,
    idle: :success,
    unknown: :muted
  }

  @spec render(Node.t(), Theme.t(), :dots | :symbols) ::
          {[{non_neg_integer, Chrome.seg()}], [Chrome.hit()]}
  def render(%Node{rect: %{w: w, h: h}}, _theme, _ind) when w < 1 or h < 1, do: {[], []}

  def render(%Node{rect: r, children: children} = node, theme, indicators) do
    g = Theme.glyphs(theme)
    states = if indicators == :symbols, do: g.state_symbols, else: g.state_dots

    ctx = %{
      theme: theme,
      r: r,
      cw: r.w - 1,
      states: states,
      g: g,
      base: Theme.style(theme, :default)
    }

    kids = Map.new(children, &{&1.id, &1})

    {lines, hits} =
      if Map.get(node.props, :collapsed),
        do: collapsed(kids, ctx),
        else: expanded(kids, ctx)

    edge = Text.text(g.edge, :muted, theme)
    blank = Cells.blank(ctx.cw, ctx.base)

    rows =
      for y <- r.y..(r.y + r.h - 1)//1 do
        {y, {r.x, r.w, Cells.concat([Map.get(lines, y, blank), edge])}}
      end

    edge_hit =
      Chrome.hit(%{x: r.x + ctx.cw, y: r.y, w: 1, h: r.h}, [:sidebar, :edge], :divider, true)

    hits = [edge_hit | hits] ++ [Chrome.hit(r, [node.id], node.role)]
    {rows, hits |> Enum.map(&clip_hit(&1, r)) |> Enum.reject(&is_nil/1)}
  end

  # --- expanded ---

  defp expanded(kids, %{r: r} = ctx) do
    bottom = r.y + r.h - 1
    split = kids[:split]
    spaces_end = if split, do: split.rect.y - 1, else: bottom

    {space_lines, space_hits} = spaces(kids[:spaces], r.y, spaces_end, ctx)

    {agent_lines, agent_hits} =
      if split, do: agents(kids[:agents], split, bottom, ctx), else: agents(nil, nil, bottom, ctx)

    toggle_x = r.x + r.w - 2
    lines = Map.new(space_lines ++ agent_lines)
    {lines, toggle_hit} = toggle(lines, kids[:toggle], toggle_x, bottom, ctx.g.collapse, ctx)

    {lines,
     toggle_hit ++
       agent_hits.split ++
       agent_hits.items ++
       space_hits.items ++
       space_hits.buttons ++ space_hits.section ++ agent_hits.section}
  end

  defp spaces(nil, _y0, _y1, _ctx), do: {[], %{items: [], buttons: [], section: []}}

  defp spaces(%Node{children: cs} = sec, y0, y1, ctx) do
    kids = Map.new(cs, &{&1.id, &1})
    header = header(sec.text, y0, ctx)
    footer_y = if y1 >= y0 + 2, do: y1
    list_end = if footer_y, do: footer_y - 1, else: y1
    {item_lines, item_hits} = list(kids[:list], [:sidebar, sec.id, :list], y0 + 2, list_end, ctx)
    {footer, buttons} = footer(kids, sec.id, footer_y, ctx)
    section = [Chrome.hit(rect(ctx, y0, y1), [:sidebar, sec.id], :section)]
    {header ++ item_lines ++ footer, %{items: item_hits, buttons: buttons, section: section}}
  end

  defp footer(_kids, _id, nil, _ctx), do: {[], []}

  defp footer(kids, id, y, %{r: r, cw: cw, theme: theme, base: base}) do
    new = Text.text(" " <> ((kids[:new] && kids[:new].text) || ""), :default, theme)

    menu =
      case kids[:menu] do
        %Node{text: t, props: %{attention: true}} ->
          Cells.concat([Text.text("● ", :accent, theme), Text.text(t || "", :default, theme)])

        %Node{text: t} ->
          Text.text(t || "", :default, theme)

        nil ->
          Cell.blank_row(0)
      end

    mw = Cell.cols(menu)
    gap = max(cw - Cell.cols(new) - mw, 0)
    row = [new, Cells.blank(gap, base), menu] |> Cells.concat() |> Text.clip(cw, base)

    hits =
      [{:new, r.x, Cell.cols(new)}, {:menu, r.x + cw - mw, mw}]
      |> Enum.filter(fn {b, _, bw} -> kids[b] && bw > 0 end)
      |> Enum.map(fn {b, x, bw} ->
        Chrome.hit(%{x: x, y: y, w: bw, h: 1}, [:sidebar, id, b], :button)
      end)

    {[{y, row}], hits}
  end

  defp agents(nil, _split, _bottom, _ctx), do: {[], %{split: [], items: [], section: []}}

  defp agents(%Node{children: cs} = sec, split, bottom, %{cw: cw, theme: theme, g: g} = ctx) do
    y = split.rect.y
    rule = {y, Text.text(String.duplicate(g.rule, cw), :muted, theme)}
    header = header(sec.text, y + 1, ctx)
    list = Enum.find(cs, &(&1.id == :list))
    {item_lines, item_hits} = list(list, [:sidebar, sec.id, :list], y + 2, bottom, ctx)
    split_hit = Chrome.hit(split.rect, [:sidebar, split.id], :divider, true)
    section = [Chrome.hit(rect(ctx, y + 1, bottom), [:sidebar, sec.id], :section)]
    {[rule | header ++ item_lines], %{split: [split_hit], items: item_hits, section: section}}
  end

  defp header(nil, _y, _ctx), do: []

  defp header(text, y, %{theme: theme, cw: cw, base: base}) do
    style = Theme.style(theme, :muted)
    style = %{style | attrs: Enum.uniq(style.attrs ++ Theme.style(theme, :strong).attrs)}
    [{y, Text.clip(Cells.text(" " <> text, style), cw, base)}]
  end

  # items top-down from the list's offset, one row per line, rows y0..y1
  defp list(list, path, y0, y1, ctx) do
    {lines, hits, _} = rows_of(items(list), path, y0, y1, ctx, &item_rows(&1, ctx))
    {lines, hits}
  end

  defp item_rows(%Node{children: groups, props: props}, %{cw: cw, theme: theme, base: base} = ctx) do
    selected = Map.get(props, :active) == true and Map.has_key?(props, :index)

    detail =
      case Map.get(props, :detail) do
        d when is_binary(d) and d != "" -> [Text.text(d, :muted, theme)]
        _ -> []
      end

    groups
    |> Enum.with_index()
    |> Enum.map(fn {group, i} -> {i, tokens(group.children, ctx)} end)
    |> Enum.concat(Enum.map(detail, &{:detail, &1}))
    |> Enum.map(fn {i, cells} ->
      indent = Cells.blank(if(i == 0, do: 1, else: 3), base)
      row = [indent, cells] |> Cells.concat() |> Text.ellipsize(cw, theme)
      row = Text.clip(row, cw, base)
      if selected, do: select(row, cw, theme), else: row
    end)
  end

  defp select(row, w, theme),
    do: Cells.restyle(row, 0, w, bg: Theme.style(theme, :selected).bg)

  # badge then a single space; other tokens joined by the separator
  defp tokens(nodes, %{theme: theme, g: g} = ctx) do
    nodes
    |> Enum.flat_map(&token(&1, ctx))
    |> Enum.reduce({[], nil}, fn {kind, cells}, {acc, prev} ->
      sep =
        case prev do
          nil -> []
          :badge -> [Text.text(" ", :default, theme)]
          _ -> [Text.text(g.sep, :muted, theme)]
        end

      {acc ++ sep ++ [cells], kind}
    end)
    |> elem(0)
    |> case do
      [] -> Cell.blank_row(0)
      pieces -> Cells.concat(pieces)
    end
  end

  defp token(%Node{role: :badge, props: %{state: s}}, ctx), do: [{:badge, badge(s, ctx)}]
  defp token(%Node{text: t}, _ctx) when t in [nil, ""], do: []
  defp token(%Node{text: t, token: tok}, %{theme: theme}), do: [{:text, Text.text(t, tok, theme)}]

  defp badge(state, %{states: states, theme: theme}) do
    Text.text(
      Map.get(states, state, states.unknown),
      Map.get(@state_tokens, state, :muted),
      theme
    )
  end

  # --- collapsed ---

  defp collapsed(kids, %{r: r, cw: cw, theme: theme, base: base, g: g} = ctx) do
    bottom = r.y + r.h - 1
    spaces = section_list(kids[:spaces])
    agents = section_list(kids[:agents])

    {ws_lines, ws_hits, y} =
      rows_of(spaces, [:sidebar, :spaces, :list], r.y, bottom - 1, ctx, fn item ->
        index = item.props |> Map.get(:index, "") |> to_string() |> String.pad_leading(2)
        row = Cells.concat([Text.text(index, :default, theme), item_badge(item, ctx)])
        row = Text.clip(row, cw, base)
        [if(Map.get(item.props, :active) == true, do: select(row, cw, theme), else: row)]
      end)

    rule =
      if y < bottom, do: [{y, Text.text(String.duplicate(g.rule, cw), :muted, theme)}], else: []

    {ag_lines, ag_hits, _} =
      if r.h >= 7 do
        rows_of(agents, [:sidebar, :agents, :list], y + 1, bottom - 1, ctx, fn item ->
          [Text.clip(Cells.concat([Cells.blank(2, base), item_badge(item, ctx)]), cw, base)]
        end)
      else
        {[], [], y}
      end

    lines = Map.new(ws_lines ++ rule ++ ag_lines)
    {lines, toggle} = toggle(lines, kids[:toggle], r.x + div(cw, 2), bottom, g.expand, ctx)
    {lines, toggle ++ ag_hits ++ ws_hits}
  end

  defp section_list(nil), do: []
  defp section_list(%Node{children: cs}), do: items(Enum.find(cs, &(&1.id == :list)))

  defp items(nil), do: []

  defp items(%Node{children: items, props: props}),
    do: Enum.drop(items, Map.get(props, :offset, 0))

  # each item's rows (`fun`) from y0 while they fit above y1; returns the next free row
  defp rows_of(items, path, y0, y1, ctx, fun) do
    {lines, hits, y, marks} =
      Enum.reduce_while(items, {[], [], y0, []}, &place(&1, &2, path, y1, ctx, fun))

    {lines |> Enum.reverse() |> marks(marks, y1, ctx), Enum.reverse(hits), y}
  end

  defp place(_item, {_, _, y, _} = acc, _path, y1, _ctx, _fun) when y > y1, do: {:halt, acc}

  defp place(item, {ls, hs, y, ms}, path, y1, ctx, fun) do
    rows = item |> fun.() |> Enum.take(y1 - y + 1)
    n = length(rows)
    drag = path == [:sidebar, :spaces, :list]
    hit = Chrome.hit(rect(ctx, y, y + n - 1), path ++ [item.id], :item, drag)
    ls = rows |> Enum.with_index(y) |> Enum.reduce(ls, fn {row, yy}, acc -> [{yy, row} | acc] end)

    ms =
      case Map.get(item.props, :drop_marker) do
        :before -> [y | ms]
        :after -> [y + n | ms]
        _ -> ms
      end

    {:cont, {ls, [hit | hs], y + n, ms}}
  end

  # the drop marker cells; an `:after` below the last item marks a blank row
  defp marks(lines, [], _y1, _ctx), do: lines

  defp marks(lines, ms, y1, %{cw: cw, base: base, g: g, theme: theme}) do
    extra = for y <- ms, y <= y1, not List.keymember?(lines, y, 0), do: {y, Cells.blank(cw, base)}

    Enum.map(lines ++ extra, fn {y, row} ->
      if y in ms, do: {y, Text.mark(row, 0, g.drop_row, theme)}, else: {y, row}
    end)
  end

  defp item_badge(%Node{children: groups}, ctx) do
    case for(%Node{children: cs} <- groups, %Node{role: :badge} = b <- cs, do: b) do
      [%Node{props: %{state: s}} | _] -> badge(s, ctx)
      [] -> Cell.blank_row(0)
    end
  end

  # --- shared ---

  # the toggle glyph over column x of the bottom line
  defp toggle(lines, nil, _x, _y, _glyph, _ctx), do: {lines, []}

  defp toggle(lines, %Node{id: id, role: role}, x, y, glyph, %{r: r, cw: cw, base: base} = ctx) do
    cx = x - r.x

    if cx >= 0 and cx < cw do
      line = Map.get(lines, y, Cells.blank(cw, base))
      cell = Text.text(glyph, :muted, ctx.theme)

      row =
        Cells.concat([Cells.fit(line, 0, cx), cell, Cells.fit(line, cx + 1, cw - cx - 1)])

      {Map.put(lines, y, row), [Chrome.hit(%{x: x, y: y, w: 1, h: 1}, [:sidebar, id], role)]}
    else
      {lines, []}
    end
  end

  defp rect(%{r: r, cw: cw}, y0, y1), do: %{x: r.x, y: y0, w: cw, h: max(y1 - y0 + 1, 0)}

  defp clip_hit(%{rect: h} = hit, r) do
    x = max(h.x, r.x)
    y = max(h.y, r.y)
    w = min(h.x + h.w, r.x + r.w) - x
    hh = min(h.y + h.h, r.y + r.h) - y
    if w > 0 and hh > 0, do: %{hit | rect: %{x: x, y: y, w: w, h: hh}}
  end
end
