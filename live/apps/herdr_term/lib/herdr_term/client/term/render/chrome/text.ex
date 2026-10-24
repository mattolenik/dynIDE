defmodule HerdrTerm.Client.Term.Render.Chrome.Text do
  @moduledoc """
  Shared chrome piece helpers over packed cells (pure): token text, pills, joining with
  a separator, clipping or padding to a width, centring and cutting with an ellipsis.
  """

  alias HerdrScene.Cell
  alias HerdrTerm.Cells
  alias HerdrTerm.Client.Term.Theme

  @doc "`str` in the style of theme token `token`."
  @spec text(binary, atom | nil, Theme.t()) :: Cell.row()
  def text(str, token, theme), do: Cells.text(str, Theme.style(theme, token))

  @doc "`str` padded by one blank on each side, all in `token`'s style."
  @spec pill(binary, atom | nil, Theme.t()) :: Cell.row()
  def pill(str, token, theme), do: text(" " <> str <> " ", token, theme)

  @doc "Pieces left to right with `sep` between them."
  @spec join([Cell.row()], Cell.row()) :: Cell.row()
  def join([], _sep), do: Cell.blank_row(0)
  def join(pieces, sep), do: pieces |> Enum.intersperse(sep) |> Cells.concat()

  @doc "Exactly `w` cells: long rows are cut, short ones padded with `style` blanks."
  @spec clip(Cell.row(), non_neg_integer, Cell.t()) :: Cell.row()
  def clip(row, w, style) do
    n = Cell.cols(row)

    cond do
      n > w -> Cells.fit(row, 0, w)
      n == w -> row
      true -> Cells.concat([row, Cells.blank(w - n, style)])
    end
  end

  @doc "`row` centred in `w` cells (the odd blank goes right), padded with `style` blanks."
  @spec center(Cell.row(), non_neg_integer, Cell.t()) :: Cell.row()
  def center(row, w, style) do
    left = max(div(w - Cell.cols(row), 2), 0)
    clip(Cells.concat([Cells.blank(left, style), row]), w, style)
  end

  @doc "At most `w` cells; a row that does not fit is cut and its last cell becomes `…`."
  @spec ellipsize(Cell.row(), non_neg_integer, Theme.t()) :: Cell.row()
  def ellipsize(row, w, theme) do
    cond do
      Cell.cols(row) <= w ->
        row

      w == 0 ->
        Cell.blank_row(0)

      true ->
        Cells.concat([
          Cells.fit(row, 0, w - 1),
          text(Theme.glyphs(theme).ellipsis, :muted, theme)
        ])
    end
  end
end
