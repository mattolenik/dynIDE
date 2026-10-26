defmodule DynideServer.Detect.Regions do
  @moduledoc """
  Detection regions: the slice of a pane snapshot a manifest rule matches against.

  Pure. Ports herdr's `region/2` and its helpers (src/detect/manifest.rs).
  Lines split as Rust `str::lines`; byte offsets count each line plus one
  newline, exactly as herdr does, so slices agree byte for byte.
  """

  @type input :: %{screen: binary, osc_title: binary, osc_progress: binary}

  @max_top_lines 65_535

  @doc "The region text named by `spec` (unknown specs yield `\"\"`)."
  @spec region(input, binary) :: binary
  def region(input, spec) do
    case String.trim(spec) do
      "osc_title" -> input.osc_title
      "osc_progress" -> input.osc_progress
      spec -> screen_region(input.screen, spec)
    end
  end

  @doc "Rust `str::lines`: split on `\\n`, strip one trailing `\\r`, no final empty line."
  @spec lines(binary) :: [binary]
  def lines(""), do: []

  def lines(content) do
    parts = String.split(content, "\n")
    parts = if List.last(parts) == "", do: Enum.drop(parts, -1), else: parts
    Enum.map(parts, &strip_cr/1)
  end

  defp strip_cr(line) do
    size = byte_size(line) - 1

    if size >= 0 and binary_part(line, size, 1) == "\r",
      do: binary_part(line, 0, size),
      else: line
  end

  defp screen_region(c, "whole_recent"), do: c
  defp screen_region(c, "after_last_prompt_marker"), do: after_last_prompt_marker(c)
  defp screen_region(c, "before_current_prompt_marker"), do: before_current_prompt_marker(c)

  defp screen_region(c, "whole_recent_without_current_prompt_marker"),
    do: if(current_prompt_index(lines(c)), do: "", else: c)

  defp screen_region(c, "current_prompt_block_marker"), do: current_prompt_block_marker(c)

  defp screen_region(c, "after_current_prompt_block_marker"),
    do: after_current_prompt_block_marker(c)

  defp screen_region(c, "prompt_box_body"), do: prompt_box_body(c)
  defp screen_region(c, "above_prompt_box"), do: above_prompt_box(c)

  defp screen_region(c, "last_non_empty_above_prompt_box"),
    do: c |> above_prompt_box() |> lines() |> Enum.reverse() |> Enum.find("", &non_empty?/1)

  defp screen_region(c, "after_last_horizontal_rule"), do: after_last_horizontal_rule(c)

  defp screen_region(c, spec) do
    cond do
      n = count(spec, ~r/\Abottom_lines\((\d+)\)\z/) -> bottom_lines(c, n)
      n = count(spec, ~r/\Abottom_non_empty_lines\((\d+)\)\z/) -> bottom_non_empty_lines(c, n)
      n = top_count(spec) -> top_non_empty_lines(c, n)
      true -> ""
    end
  end

  defp count(spec, re) do
    case Regex.run(re, spec) do
      [_, n] -> String.to_integer(n)
      nil -> nil
    end
  end

  defp top_count(spec) do
    case Regex.run(~r/\Atop_non_empty_lines\(([1-9]\d*)\)\z/, spec) do
      [_, n] -> n |> String.to_integer() |> then(&if(&1 <= @max_top_lines, do: &1))
      nil -> nil
    end
  end

  defp bottom_lines(c, n) do
    ls = lines(c)
    from_line(c, ls, max(length(ls) - n, 0))
  end

  defp bottom_non_empty_lines(c, n) do
    ls = lines(c)

    ls
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.filter(fn {l, _} -> non_empty?(l) end)
    |> Enum.take(n)
    |> List.last()
    |> case do
      nil -> ""
      {_, i} -> from_line(c, ls, i)
    end
  end

  defp top_non_empty_lines(c, n) do
    ls = lines(c)

    ls
    |> Enum.with_index()
    |> Enum.filter(fn {l, _} -> non_empty?(l) end)
    |> Enum.take(n)
    |> List.last()
    |> case do
      nil -> ""
      {_, i} -> upto_line(c, ls, i + 1)
    end
  end

  defp after_last_prompt_marker(c) do
    ls = lines(c)

    case last_index(ls, &prompt_line?/1) do
      nil -> c
      i -> from_line(c, ls, i + 1)
    end
  end

  # herdr sums line lengths without clamping to the line count here; same result.
  defp before_current_prompt_marker(c) do
    ls = lines(c)

    case current_prompt_index(ls) do
      nil -> c
      i -> upto_line(c, ls, i)
    end
  end

  defp current_prompt_block_marker(c) do
    ls = lines(c)

    with i when is_integer(i) <- current_prompt_index(ls),
         j when is_integer(j) <- last_index(Enum.take(ls, i), &block_marker?/1) do
      Enum.at(ls, j)
    else
      nil -> ""
    end
  end

  defp after_current_prompt_block_marker(c) do
    ls = lines(c)

    with i when is_integer(i) <- current_prompt_index(ls),
         j when is_integer(j) <- last_index(Enum.take(ls, i), &block_marker?/1) do
      from_line(c, ls, j)
    else
      nil -> ""
    end
  end

  defp current_prompt_index(ls) do
    case last_index(ls, &prompt_line?/1) do
      nil -> nil
      i -> if Enum.any?(Enum.drop(ls, i + 1), &block_marker?/1), do: nil, else: i
    end
  end

  defp prompt_line?(line), do: line == "›" or String.starts_with?(line, "› ")
  defp block_marker?(line), do: String.starts_with?(line, ["•", "■", "✗", "✓"])

  defp prompt_box_body(c) do
    ls = lines(c)

    case box_top(ls) do
      nil ->
        ""

      top ->
        rest = ls |> Enum.drop(top + 1) |> Enum.find_index(&rule?/1)
        end_index = if rest, do: top + 1 + rest, else: length(ls)
        start = offset(c, ls, top + 1)
        binary_part(c, start, max(offset(c, ls, end_index) - start, 0))
    end
  end

  defp above_prompt_box(c) do
    ls = lines(c)

    case box_top(ls) do
      nil -> c
      top -> upto_line(c, ls, top)
    end
  end

  # The top border is the second horizontal rule counting from the bottom.
  defp box_top(ls) do
    ls
    |> Enum.with_index()
    |> Enum.filter(fn {l, _} -> rule?(l) end)
    |> Enum.reverse()
    |> case do
      [_, {_, i} | _] -> i
      _ -> nil
    end
  end

  defp after_last_horizontal_rule(c) do
    {last, _} =
      Enum.reduce(lines(c), {0, 0}, fn line, {last, off} ->
        next = off + byte_size(line) + 1
        {if(rule?(line), do: min(next, byte_size(c)), else: last), next}
      end)

    binary_part(c, last, byte_size(c) - last)
  end

  defp rule?(line) do
    trimmed = String.trim(line)
    rest = String.trim_leading(trimmed, "─")
    dashes = div(byte_size(trimmed) - byte_size(rest), byte_size("─"))
    dashes > 0 and (String.trim_leading(rest) == "" or dashes >= 3)
  end

  defp non_empty?(line), do: String.trim(line) != ""

  defp last_index(list, fun) do
    list
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {x, i}, acc -> if fun.(x), do: i, else: acc end)
  end

  defp from_line(c, ls, i) do
    off = offset(c, ls, i)
    binary_part(c, off, byte_size(c) - off)
  end

  defp upto_line(c, ls, i), do: binary_part(c, 0, offset(c, ls, i))

  defp offset(c, ls, i) do
    ls |> Enum.take(i) |> Enum.reduce(0, &(byte_size(&1) + 1 + &2)) |> min(byte_size(c))
  end
end
