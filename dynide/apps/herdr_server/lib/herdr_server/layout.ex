defmodule HerdrServer.Layout do
  @moduledoc """
  Pure BSP tile layout: a port of herdr's `src/layout.rs` plus the pane-border rule
  of `apply_pane_chrome` (gaps, outer borders; `pane_borders` auto/always/off) and zoom.

  Tree: `{:pane, id} | {:split, :horizontal | :vertical, ratio, first, second}`.
  `:horizontal` is side by side, `:vertical` is stacked. Rects are `%{x, y, w, h}`.
  """

  defstruct [:root, :focus, prev_focus: nil]

  @type id :: term()
  @type rect :: %{
          x: non_neg_integer(),
          y: non_neg_integer(),
          w: non_neg_integer(),
          h: non_neg_integer()
        }
  @type dir :: :horizontal | :vertical
  @type tree :: {:pane, id()} | {:split, dir(), float(), tree(), tree()}
  @type nav :: :left | :right | :up | :down
  @type t :: %__MODULE__{root: tree(), focus: id(), prev_focus: id() | nil}

  @spec new(id()) :: t()
  def new(id), do: %__MODULE__{root: {:pane, id}, focus: id}

  @spec pane_ids(t()) :: [id()]
  def pane_ids(%__MODULE__{root: root}), do: ids(root)

  @spec count(t()) :: pos_integer()
  def count(l), do: length(pane_ids(l))

  @spec panes(t(), rect()) :: [%{id: id(), rect: rect(), focused: boolean()}]
  def panes(%__MODULE__{root: root, focus: focus}, rect) do
    root |> leaves(rect) |> Enum.map(fn {id, r} -> %{id: id, rect: r, focused: id == focus} end)
  end

  @spec splits(t(), rect()) :: [map()]
  def splits(%__MODULE__{root: root}, rect), do: collect_splits(root, rect, [])

  @doc "Split `target`; the new pane is second and takes focus. Unknown target: unchanged."
  @spec split(t(), id(), dir(), id(), float()) :: t()
  def split(l, target, dir, new_id, ratio \\ 0.5) do
    if target in pane_ids(l) do
      node = {:split, dir, clamp(ratio), {:pane, target}, {:pane, new_id}}
      set_focus(%{l | root: replace_leaf(l.root, target, node)}, new_id)
    else
      l
    end
  end

  @spec close(t(), id()) :: {:ok, t()} | :last
  def close(l, id) do
    ids = pane_ids(l)

    cond do
      length(ids) <= 1 or id not in ids ->
        :last

      id == l.focus ->
        pos = Enum.find_index(ids, &(&1 == id))
        ordered = Enum.at(ids, pos + 1) || Enum.at(ids, pos - 1)
        new_focus = if l.prev_focus in ids and l.prev_focus != id, do: l.prev_focus, else: ordered
        {:ok, %{l | root: remove(l.root, id), focus: new_focus, prev_focus: nil}}

      true ->
        prev = if l.prev_focus == id, do: nil, else: l.prev_focus
        {:ok, %{l | root: remove(l.root, id), prev_focus: prev}}
    end
  end

  @spec focus(t(), id()) :: t()
  def focus(l, id), do: if(id in pane_ids(l), do: set_focus(l, id), else: l)

  @spec find_in_direction(t(), rect(), id(), nav()) :: id() | nil
  def find_in_direction(l, rect, from, nav) do
    ps = panes(l, rect)

    case Enum.find(ps, &(&1.id == from)) do
      nil ->
        nil

      %{rect: fr} ->
        ps
        |> Enum.with_index()
        |> Enum.filter(fn {p, _} -> p.id != from and beside?(p.rect, fr, nav) end)
        |> Enum.min_by(
          fn {p, i} ->
            {edge_distance(p.rect, fr, nav), -overlap(p.rect, fr, nav), center(p.rect, fr, nav),
             i}
          end,
          fn -> nil end
        )
        |> case do
          nil -> nil
          {p, _} -> p.id
        end
    end
  end

  @doc "Resize the nearest split on the focused pane's `nav` edge; `delta` is positive."
  @spec resize(t(), rect(), nav(), float()) :: t()
  def resize(l, rect, nav, delta) do
    fr = Enum.find(panes(l, rect), & &1.focused)
    all = splits(l, rect)
    dir = if nav in [:left, :right], do: :horizontal, else: :vertical

    with %{rect: fr} <- fr,
         %{path: path} <- nearest(all, dir, fr, nav) || nearest(all, dir, fr, opposite(nav)) do
      adj = if nav in [:right, :down], do: delta, else: -delta
      set_ratio(l, path, (get_ratio(l.root, path) || 0.5) + adj)
    else
      _ -> l
    end
  end

  @spec swap(t(), id(), id()) :: t()
  def swap(l, a, b) do
    ids = pane_ids(l)

    if a != b and a in ids and b in ids do
      %{l | root: swap_ids(l.root, a, b)}
    else
      l
    end
  end

  @spec set_ratio(t(), [boolean()], float()) :: t()
  def set_ratio(l, path, ratio), do: %{l | root: put_ratio(l.root, path, clamp(ratio))}

  @type borders :: :auto | :always | :off
  @type opts :: %{zoom: id() | nil, borders: borders()}
  @type entry :: %{id: id(), rect: rect(), border: map() | nil}

  @doc """
  The pane rects of a tab: the one function View, Actions and the Store size panes with.
  A `zoom` id in the layout gets the whole `area` with no border (the other panes have no
  rect); otherwise `borders(panes(layout, area), area, opts.borders)`.
  """
  @spec rects(t(), rect(), opts()) :: [entry()]
  def rects(l, area, %{zoom: zoom, borders: mode}) do
    if zoomed?(l, zoom),
      do: [%{id: zoom, rect: area, border: nil}],
      else: borders(panes(l, area), area, mode)
  end

  @doc "Whether `zoom` names a pane of the layout (a zoom `rects/3` honours)."
  @spec zoomed?(t(), id() | nil) :: boolean()
  def zoomed?(l, zoom), do: zoom != nil and zoom in pane_ids(l)

  @doc "`rects/3` opts for `tab` (nil: a tab with no zoom) under the `App.Ui` `ui`."
  @spec opts(map() | nil, map()) :: opts()
  def opts(tab, ui),
    do: %{zoom: tab && Map.get(tab, :zoom), borders: Map.get(ui, :pane_borders, :auto)}

  @doc """
  Content size of pane `id`: its `rects/3` rect, or its unzoomed tile when a zoom hides it
  (the size a hidden pane keeps). nil when `id` is not in the layout.
  """
  @spec size(t(), rect(), opts(), id()) ::
          %{cols: non_neg_integer(), rows: non_neg_integer()} | nil
  def size(l, area, opts, id) do
    find = &Enum.find(rects(l, area, &1), fn e -> e.id == id end)

    case find.(opts) || find.(%{opts | zoom: nil}) do
      %{rect: r} -> %{cols: r.w, rows: r.h}
      nil -> nil
    end
  end

  @doc """
  Pane chrome. `:auto` (herdr's default): one pane has no border, several each get all four
  edges around the layout rect and a content rect inset by one cell (origin capped at the
  outer rect's end, so the content rect always lies inside the border rect). `:always`
  borders a single pane too; `:off` never borders, so the panes tile the area.
  """
  @spec borders([%{id: id(), rect: rect()}], rect(), borders()) :: [entry()]
  def borders(panes, _rect, :off), do: Enum.map(panes, &bare/1)
  def borders([p], _rect, :auto), do: [bare(p)]
  def borders(panes, _rect, _mode), do: Enum.map(panes, &bordered/1)

  defp bare(%{id: id, rect: r}), do: %{id: id, rect: r, border: nil}

  defp bordered(%{id: id, rect: r}) do
    content = %{
      x: min(r.x + 1, r.x + r.w),
      y: min(r.y + 1, r.y + r.h),
      w: max(r.w - 2, 0),
      h: max(r.h - 2, 0)
    }

    %{
      id: id,
      rect: content,
      border: %{rect: r, edges: [:top, :bottom, :left, :right], title: nil}
    }
  end

  # --- internals ---

  defp clamp(r), do: r |> max(0.1) |> min(0.9)

  defp set_focus(%{focus: id} = l, id), do: l
  defp set_focus(l, id), do: %{l | prev_focus: l.focus, focus: id}

  defp ids({:pane, id}), do: [id]
  defp ids({:split, _, _, a, b}), do: ids(a) ++ ids(b)

  defp leaves({:pane, id}, r), do: [{id, r}]

  defp leaves({:split, dir, ratio, a, b}, r) do
    {ra, rb} = split_rect(r, dir, ratio)
    leaves(a, ra) ++ leaves(b, rb)
  end

  defp split_rect(r, :horizontal, ratio) do
    fw = round(r.w * ratio)
    {%{r | w: fw}, %{r | x: r.x + fw, w: max(r.w - fw, 0)}}
  end

  defp split_rect(r, :vertical, ratio) do
    fh = round(r.h * ratio)
    {%{r | h: fh}, %{r | y: r.y + fh, h: max(r.h - fh, 0)}}
  end

  defp collect_splits({:pane, _}, _r, _path), do: []

  defp collect_splits({:split, dir, ratio, a, b}, r, path) do
    {ra, rb} = split_rect(r, dir, ratio)
    pos = if dir == :horizontal, do: ra.x + ra.w, else: ra.y + ra.h

    [%{pos: pos, direction: dir, ratio: ratio, area: r, path: path}] ++
      collect_splits(a, ra, path ++ [false]) ++ collect_splits(b, rb, path ++ [true])
  end

  defp replace_leaf({:pane, id}, id, node), do: node
  defp replace_leaf({:pane, _} = p, _, _), do: p

  defp replace_leaf({:split, d, r, a, b}, id, node),
    do: {:split, d, r, replace_leaf(a, id, node), replace_leaf(b, id, node)}

  # returns tree, or nil when the whole subtree was the removed leaf
  defp remove({:pane, id}, id), do: nil
  defp remove({:pane, _} = p, _), do: p

  defp remove({:split, d, r, a, b}, id) do
    case {remove(a, id), remove(b, id)} do
      {nil, s} -> s
      {f, nil} -> f
      {f, s} -> {:split, d, r, f, s}
    end
  end

  defp swap_ids({:pane, a}, a, b), do: {:pane, b}
  defp swap_ids({:pane, b}, a, b), do: {:pane, a}
  defp swap_ids({:pane, _} = p, _, _), do: p

  defp swap_ids({:split, d, r, f, s}, a, b),
    do: {:split, d, r, swap_ids(f, a, b), swap_ids(s, a, b)}

  defp put_ratio({:split, d, _, a, b}, [], ratio), do: {:split, d, ratio, a, b}

  defp put_ratio({:split, d, r, a, b}, [false | p], ratio),
    do: {:split, d, r, put_ratio(a, p, ratio), b}

  defp put_ratio({:split, d, r, a, b}, [true | p], ratio),
    do: {:split, d, r, a, put_ratio(b, p, ratio)}

  defp put_ratio(leaf, _, _), do: leaf

  defp get_ratio({:split, _, r, _, _}, []), do: r
  defp get_ratio({:split, _, _, a, _}, [false | p]), do: get_ratio(a, p)
  defp get_ratio({:split, _, _, _, b}, [true | p]), do: get_ratio(b, p)
  defp get_ratio(_, _), do: nil

  # --- navigation / resize geometry ---

  defp ranges_overlap?(as, al, bs, bl), do: as < bs + bl and as + al > bs

  defp beside?(r, fr, :left), do: r.x + r.w <= fr.x and ranges_overlap?(r.y, r.h, fr.y, fr.h)
  defp beside?(r, fr, :right), do: r.x >= fr.x + fr.w and ranges_overlap?(r.y, r.h, fr.y, fr.h)
  defp beside?(r, fr, :up), do: r.y + r.h <= fr.y and ranges_overlap?(r.x, r.w, fr.x, fr.w)
  defp beside?(r, fr, :down), do: r.y >= fr.y + fr.h and ranges_overlap?(r.x, r.w, fr.x, fr.w)

  defp edge_distance(r, fr, :left), do: max(fr.x - (r.x + r.w), 0)
  defp edge_distance(r, fr, :right), do: max(r.x - (fr.x + fr.w), 0)
  defp edge_distance(r, fr, :up), do: max(fr.y - (r.y + r.h), 0)
  defp edge_distance(r, fr, :down), do: max(r.y - (fr.y + fr.h), 0)

  defp axis(r, fr, nav) when nav in [:left, :right], do: {r.y, r.h, fr.y, fr.h}
  defp axis(r, fr, _), do: {r.x, r.w, fr.x, fr.w}

  defp overlap(r, fr, nav) do
    {as, al, bs, bl} = axis(r, fr, nav)
    max(min(as + al, bs + bl) - max(as, bs), 0)
  end

  defp center(r, fr, nav) do
    {as, al, bs, bl} = axis(r, fr, nav)
    abs(as * 2 + al - (bs * 2 + bl))
  end

  defp nearest(splits, dir, fr, nav) do
    splits
    |> Enum.filter(fn s ->
      s.direction == dir and area_overlaps?(s.area, fr, nav) and split_distance(s, fr, nav) <= 1
    end)
    |> Enum.min_by(&split_distance(&1, fr, nav), fn -> nil end)
  end

  defp area_overlaps?(a, fr, nav) when nav in [:left, :right],
    do: ranges_overlap?(a.y, a.h, fr.y, fr.h)

  defp area_overlaps?(a, fr, _), do: ranges_overlap?(a.x, a.w, fr.x, fr.w)

  defp split_distance(s, fr, :left), do: abs(s.pos - fr.x)
  defp split_distance(s, fr, :right), do: abs(s.pos - (fr.x + fr.w))
  defp split_distance(s, fr, :up), do: abs(s.pos - fr.y)
  defp split_distance(s, fr, :down), do: abs(s.pos - (fr.y + fr.h))

  defp opposite(:left), do: :right
  defp opposite(:right), do: :left
  defp opposite(:up), do: :down
  defp opposite(:down), do: :up
end
