defmodule DynideTerm.Demo.FakeRows do
  @moduledoc """
  Pure fake screen for `mix dynide_term.demo`: a header naming the size and
  OS pid, then a bordered box with a tick counter, the last input as hex, a
  colour gradient and a wide-character row. Rows beyond the content are blank.
  """

  alias DynideScene.Cell

  @type state :: %{tick: non_neg_integer(), last_input: binary(), pid: binary()}

  @doc "Packed rows `{0, row}..{rows - 1, row}`, each exactly `cols` wide."
  @spec frame(pos_integer(), pos_integer(), state()) :: [{non_neg_integer(), Cell.row()}]
  def frame(cols, rows, %{tick: tick, last_input: input, pid: pid}) do
    inner = [
      text("tick: #{tick}"),
      text("last input: " <> Base.encode16(input, case: :lower)),
      gradient(cols),
      text("wide: ") ++ wide("漢字") ++ text(" ok")
    ]

    lines =
      [text("herdr-live demo #{cols}x#{rows} pid #{pid}", [:bold]), border(cols, "┌", "┐")] ++
        Enum.map(inner, &boxed/1) ++ [border(cols, "└", "┘")]

    for y <- 0..(rows - 1), do: {y, lines |> Enum.at(y, []) |> fit(cols) |> Cell.encode_row()}
  end

  defp text(s, attrs \\ []),
    do: for(g <- String.graphemes(s), do: %Cell{glyph: g, attrs: attrs})

  defp wide(s),
    do: Enum.flat_map(String.graphemes(s), &[%Cell{glyph: &1, width: 2}, %Cell{width: 0}])

  defp gradient(cols) do
    for x <- 0..max(cols - 5, 0),
        do: %Cell{bg: {:rgb, div(x * 255, max(cols - 5, 1)), 64, 160}}
  end

  defp border(cols, l, r), do: text(l <> String.duplicate("─", max(cols - 2, 0)) <> r)

  # Box content sits after "│ "; the right border is drawn over the last column.
  defp boxed(cells), do: {text("│ ") ++ cells, text("│")}

  defp fit({cells, right}, cols) when cols >= 2,
    do: fit(cells, cols - length(right)) ++ right

  defp fit({cells, _right}, cols), do: fit(cells, cols)

  defp fit(cells, cols) do
    cells = Enum.take(cells, cols)
    # Never keep a wide head whose spacer tail was cut off.
    cells =
      if match?(%Cell{width: 2}, List.last(cells)), do: List.delete_at(cells, -1), else: cells

    cells ++ List.duplicate(%Cell{}, cols - length(cells))
  end
end
