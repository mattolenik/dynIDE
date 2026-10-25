defmodule HerdrTerm.Client.Term.Render.Chrome.Toast do
  @moduledoc """
  The `:toast` region (pure, herdr `render_notification_card`): a square `:muted` border,
  `"● title"` on the first inner row (the dot in the node's token, the title bold), the
  `:body` text indented 2 in `:muted` on the second, all in the region rect. A rect
  under 3x3 is a blank box. One hit: the card (`[id]`).
  """

  alias HerdrScene.Scene.Node
  alias HerdrTerm.Cells
  alias HerdrTerm.Client.Term.Render.Chrome
  alias HerdrTerm.Client.Term.Render.Chrome.Text
  alias HerdrTerm.Client.Term.Theme

  @spec render(Node.t(), Theme.t()) :: {[{non_neg_integer, Chrome.seg()}], [Chrome.hit()]}
  def render(%Node{id: id, rect: r} = n, theme) do
    {rows(n, r, theme), [Chrome.hit(r, [id], :toast)]}
  end

  defp rows(_n, %{w: w, h: h} = r, theme) when w < 3 or h < 3 do
    blank = Cells.blank(r.w, Theme.style(theme, :default))
    for y <- r.y..(r.y + r.h - 1)//1, do: {y, {r.x, r.w, blank}}
  end

  defp rows(n, r, theme) do
    g = Theme.glyphs(theme)
    b = Theme.style(theme, :muted)
    w = r.w - 2
    blank = Theme.style(theme, :default)
    v = Cells.text(g.v, b)

    title =
      Cells.concat([
        Text.text(g.bullet, n.token, theme),
        Text.text(" " <> (n.text || ""), :strong, theme)
      ])

    body =
      case n.children do
        [%Node{text: t} | _] when is_binary(t) -> Text.text("  " <> t, :muted, theme)
        _ -> Cells.blank(0, blank)
      end

    inner = [title, body] ++ List.duplicate(Cells.blank(0, blank), max(r.h - 4, 0))

    mid =
      inner
      |> Enum.take(r.h - 2)
      |> Enum.with_index(r.y + 1)
      |> Enum.map(fn {row, y} ->
        {y, {r.x, r.w, Cells.concat([v, Text.clip(row, w, blank), v])}}
      end)

    top = Cells.concat([Cells.text(g.tl, b), Cells.repeat(g.h, w, b), Cells.text(g.tr, b)])
    bottom = Cells.concat([Cells.text(g.bl, b), Cells.repeat(g.h, w, b), Cells.text(g.br, b)])
    [{r.y, {r.x, r.w, top}}] ++ mid ++ [{r.y + r.h - 1, {r.x, r.w, bottom}}]
  end
end
