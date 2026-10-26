defmodule DynideTerm.Client.Term.Render.Chrome.Status do
  @moduledoc """
  The status row region (pure): its `:text` and `:keycap` children left to right with one
  blank between them, the `:hint` text right-aligned when it fits. Keycaps (the mode bar
  hints) default to `:accent`; texts use their own token. Tabs nested in a status are not
  drawn (the tab bar is its own region). No hits.
  """

  alias DynideScene.Cell
  alias DynideScene.Scene.Node
  alias DynideTerm.Cells
  alias DynideTerm.Client.Term.Render.Chrome
  alias DynideTerm.Client.Term.Render.Chrome.Text
  alias DynideTerm.Client.Term.Theme

  @spec render(Node.t(), Theme.t()) :: {[{non_neg_integer, Chrome.seg()}], [Chrome.hit()]}
  def render(%Node{rect: r, children: children}, theme) do
    base = Theme.style(theme, :default)
    {hints, rest} = Enum.split_with(children, &(&1.id == :hint))
    left = rest |> Enum.flat_map(&pieces(&1, theme)) |> Text.join(Cells.blank(1, base))
    hint = hints |> List.last() |> hint_piece(theme)
    hw = if hint, do: Cell.cols(hint), else: 0

    first =
      if hint && hw <= r.w,
        do: Cell.concat([Text.clip(left, r.w - hw, base), hint]),
        else: Text.clip(left, r.w, base)

    rows =
      for y <- r.y..(r.y + r.h - 1)//1,
          do: {y, {r.x, r.w, if(y == r.y, do: first, else: Cells.blank(r.w, base))}}

    {rows, []}
  end

  defp hint_piece(nil, _), do: nil
  defp hint_piece(%Node{text: t}, _) when t in [nil, ""], do: nil
  defp hint_piece(%Node{text: t, token: tok}, theme), do: Text.text(t, tok, theme)

  defp pieces(%Node{role: :text, text: t}, _) when t in [nil, ""], do: []
  defp pieces(%Node{role: :text, text: t, token: tok}, theme), do: [Text.text(t, tok, theme)]

  defp pieces(%Node{role: :keycap, text: t, token: tok, props: p}, theme) do
    label = if t in [nil, ""], do: Enum.map_join(p.mods ++ [p.key], "+", &to_string/1), else: t
    [Text.text(label, tok || :accent, theme)]
  end

  defp pieces(%Node{role: role}, _) when role in [:tabs, :tab, :divider], do: []
  defp pieces(%Node{children: cs}, theme), do: Enum.flat_map(cs, &pieces(&1, theme))
end
