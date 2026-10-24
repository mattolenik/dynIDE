defmodule HerdrServer.Client.Words do
  @moduledoc """
  Pure word bounds for double-click selection (herdr `word_bounds_at_column`).

  `word_at/2` takes one decoded row (`HerdrScene.Cell.decode_row/1`) and a display
  column and returns the inclusive display columns of the word there, or `nil` (an
  empty or whitespace cell, even inside a quoted path, a separator, or nothing left after trimming). In order:

    1. an `http://`/`https://` URL running to the next whitespace, with trailing
       `" ' `` ` `` . , ; : ! ?` trimmed and `) ] }` trimmed unless balanced inside;
    2. a quoted path: text inside `"`, `'` or `` ` `` (unescaped) containing `/`;
    3. the token between separators (whitespace and `| ( ) [ ] { } , ; ! （ ） ： 、 。 ，`)
       with leading `( [ { < " ' `` ` `` and trailing `) ] } > " ' `` ` `` . , ; : ! ?`
       trimmed, and a `$` right after a trailing wrapper trimmed first.

  A wide cell covers its column and its width-0 tail's; clicking either selects it.

  `text_cells/1` and `url_span/2` are shared with `HerdrServer.Client.Links`: a text
  cell is `{glyph, first_col, last_col, ...}` (an empty glyph reads as a space) and
  spans are inclusive indexes into a tuple of text cells.
  """

  alias HerdrScene.Cell

  @type span :: {non_neg_integer, non_neg_integer}

  @url_trim ~w(" ' ` . , ; : ! ?)
  @closers %{")" => "(", "]" => "[", "}" => "{"}
  @quotes ~w(" ' `)
  @separators ~w(| \( \) [ ] { } , ; ! （ ） ： 、 。 ，)
  @leading ~w(\( [ { < " ' `)
  @trailing ~w(\) ] } > " ' ` . , ; : ! ?)

  @spec word_at([Cell.t()], integer) :: span | nil
  def word_at(cells, col) do
    tc = cells |> text_cells() |> List.to_tuple()

    with i when is_integer(i) <- index_at(tc, col),
         false <- blank?(g(tc, i)),
         {s, e} <- url_span(tc, i) || quoted_span(tc, i) || token_span(tc, i) do
      {elem(elem(tc, s), 1), elem(elem(tc, e), 2)}
    else
      _ -> nil
    end
  end

  @doc "Text cells `{glyph, first_col, last_col}` of a decoded row; wide tails are folded in."
  @spec text_cells([Cell.t()]) :: [{binary, non_neg_integer, non_neg_integer}]
  def text_cells(cells) do
    cells
    |> Enum.with_index()
    |> Enum.reject(fn {c, _} -> c.width == 0 end)
    |> Enum.map(fn {c, x} -> {glyph(c.glyph), x, x + max(c.width, 1) - 1} end)
  end

  @doc "True for an empty or whitespace glyph."
  @spec blank?(binary) :: boolean
  def blank?(g), do: String.trim(g) == ""

  @doc """
  The trimmed `http(s)://` URL span containing index `i` of a text-cell tuple, or nil.
  """
  @spec url_span(tuple, non_neg_integer) :: span | nil
  def url_span(tc, i), do: url_scan(tc, i, 0)

  defp url_scan(tc, i, start) when start <= i do
    if prefix?(tc, start, "http://") or prefix?(tc, start, "https://"),
      do: url_from(tc, i, start, extend_right(tc, start, &blank?/1)),
      else: url_scan(tc, i, start + 1)
  end

  defp url_scan(_, _, _), do: nil

  defp url_from(tc, i, _start, e) when e < i, do: url_scan(tc, i, e + 1)

  defp url_from(tc, i, start, e) do
    case trim_url(tc, start, e) do
      {_, e2} = span when i <= e2 -> span
      _ -> nil
    end
  end

  defp trim_url(_, s, e) when e < s, do: nil

  defp trim_url(tc, s, e) do
    g = g(tc, e)

    cond do
      g in @url_trim ->
        trim_url(tc, s, e - 1)

      Map.has_key?(@closers, g) and not balanced?(tc, s, e, @closers[g], g) ->
        trim_url(tc, s, e - 1)

      true ->
        {s, e}
    end
  end

  defp balanced?(tc, s, e, open, close) do
    Enum.reduce(s..(e - 1)//1, 0, fn k, acc ->
      case g(tc, k) do
        ^open -> acc + 1
        ^close -> acc - 1
        _ -> acc
      end
    end) > 0
  end

  defp quoted_span(tc, i) do
    if g(tc, i) in @quotes, do: nil, else: Enum.find_value(@quotes, &quoted_by(tc, i, &1))
  end

  # Unescaped quotes pair up left to right; the pair around i must contain a `/`.
  defp quoted_by(tc, i, q) do
    0..(tuple_size(tc) - 1)//1
    |> Enum.filter(&(g(tc, &1) == q and not escaped?(tc, &1)))
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.find_value(fn [open, close] ->
      if open < i and i < close and Enum.any?((open + 1)..(close - 1)//1, &(g(tc, &1) == "/")),
        do: {open + 1, close - 1}
    end)
  end

  defp escaped?(tc, idx) do
    slashes =
      idx
      |> Stream.iterate(&(&1 - 1))
      |> Stream.drop(1)
      |> Enum.take_while(&(&1 >= 0 and g(tc, &1) == "\\"))

    rem(length(slashes), 2) == 1
  end

  defp token_span(tc, i) do
    if separator?(g(tc, i)) do
      nil
    else
      s = extend_left(tc, i, &separator?/1)
      e = extend_right(tc, i, &separator?/1)

      case trim_token(tc, s, e) do
        {s2, e2} = span when s2 <= i and i <= e2 -> span
        _ -> nil
      end
    end
  end

  defp trim_token(tc, s, e) do
    s = Enum.find(s..e//1, e + 1, &(g(tc, &1) not in @leading))
    e = if s < e and g(tc, e) == "$" and g(tc, e - 1) in @trailing, do: e - 1, else: e
    e = Enum.find(e..s//-1, s - 1, &(g(tc, &1) not in @trailing))
    if s <= e, do: {s, e}
  end

  defp separator?(g), do: blank?(g) or g in @separators

  defp extend_left(tc, i, stop?) do
    if i > 0 and not stop?.(g(tc, i - 1)), do: extend_left(tc, i - 1, stop?), else: i
  end

  defp extend_right(tc, i, stop?) do
    if i + 1 < tuple_size(tc) and not stop?.(g(tc, i + 1)),
      do: extend_right(tc, i + 1, stop?),
      else: i
  end

  defp prefix?(tc, start, prefix) do
    prefix
    |> String.graphemes()
    |> Enum.with_index(start)
    |> Enum.all?(fn {ch, k} -> k < tuple_size(tc) and g(tc, k) == ch end)
  end

  defp index_at(tc, col) do
    Enum.find(0..(tuple_size(tc) - 1)//1, fn k ->
      {_, a, b} = elem(tc, k)
      a <= col and col <= b
    end)
  end

  defp g(tc, k), do: elem(elem(tc, k), 0)
  defp glyph(""), do: " "
  defp glyph(g), do: g
end
