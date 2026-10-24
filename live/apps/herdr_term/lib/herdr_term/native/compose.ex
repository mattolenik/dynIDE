defmodule HerdrTerm.Native.Compose do
  @moduledoc """
  Policy-free row assembly in the `herdr_term` crate, behind
  `HerdrTerm.Client.Term.Render.Compose.frame/4` with `:nif` (a measured
  prototype; Render uses the Elixir assembler). It joins packed-cell pieces
  that Elixir already built and knows nothing of panes, borders, themes or
  overlays.
  """

  alias HerdrTerm.Native

  @typedoc "Columns `off..off + w - 1` of `row` (`Cells.fit/3` semantics) placed at screen column `x`."
  @type seg :: {x :: non_neg_integer, w :: non_neg_integer, row :: binary, off :: non_neg_integer}

  @doc """
  One packed row of exactly `cols` columns per list of segments, each list
  sorted by `x` (on equal `x` the earlier segment wins; a segment starting
  left of what is already placed keeps only its uncovered columns). Raises
  `ArgumentError` on a malformed row.
  """
  @spec rows(non_neg_integer, [[seg]]) :: [binary]
  def rows(cols, rows), do: Native.compose_rows(cols, rows)
end
