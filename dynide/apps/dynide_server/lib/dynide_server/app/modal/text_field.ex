defmodule DynideServer.App.Modal.TextField do
  @moduledoc """
  Pure single-line text editing for modal inputs: `%{text, cursor}` with the cursor in
  graphemes (`0..String.length(text)`). Plain data, so it lives in modal state.

  `key/2` handles printable keys (no ctrl, alt, meta or super), Backspace, Delete,
  Left, Right, Home and End, and returns `{:ok, field}` or `:ignore` for every other key
  (Enter, Esc and shortcuts belong to the kind). Text is capped at #{64} graphemes;
  inserted text drops control characters (a pasted newline never submits).
  """

  @max 64

  @type t :: %{text: binary, cursor: non_neg_integer}

  @spec new(binary) :: t
  def new(text) do
    text = text |> clean() |> String.slice(0, @max)
    %{text: text, cursor: String.length(text)}
  end

  @spec clear(t) :: t
  def clear(_field), do: %{text: "", cursor: 0}

  @spec max_length() :: pos_integer
  def max_length, do: @max

  @doc "Inserts `str` at the cursor, cut to the length cap."
  @spec insert(t, binary) :: t
  def insert(%{text: text, cursor: c}, str) do
    {before, rest} = split(text, c)
    room = @max - String.length(text)
    add = str |> clean() |> String.slice(0, max(room, 0))
    %{text: before <> add <> rest, cursor: c + String.length(add)}
  end

  @spec key(t, tuple) :: {:ok, t} | :ignore
  def key(_f, {:key, %{event: :release}}), do: :ignore

  def key(f, {:key, %{key: k, mods: mods} = ev}) do
    cond do
      Enum.any?(mods, &(&1 in [:ctrl, :alt, :meta, :super, :hyper])) -> :ignore
      is_binary(k) -> {:ok, insert(f, Map.get(ev, :text) || k)}
      true -> edit(f, k)
    end
  end

  def key(_f, _other), do: :ignore

  defp edit(%{cursor: 0}, :backspace), do: :ignore

  defp edit(%{text: t, cursor: c}, :backspace) do
    {before, rest} = split(t, c)
    {:ok, %{text: String.slice(before, 0, c - 1) <> rest, cursor: c - 1}}
  end

  defp edit(%{text: t, cursor: c} = f, :delete) do
    {before, rest} = split(t, c)
    if rest == "", do: :ignore, else: {:ok, %{f | text: before <> String.slice(rest, 1..-1//1)}}
  end

  defp edit(%{cursor: c} = f, :left), do: {:ok, %{f | cursor: max(c - 1, 0)}}

  defp edit(%{text: t, cursor: c} = f, :right),
    do: {:ok, %{f | cursor: min(c + 1, String.length(t))}}

  defp edit(f, :home), do: {:ok, %{f | cursor: 0}}
  defp edit(%{text: t} = f, :end), do: {:ok, %{f | cursor: String.length(t)}}
  defp edit(_f, _key), do: :ignore

  defp split(text, c), do: {String.slice(text, 0, c), String.slice(text, c..-1//1)}

  defp clean(str), do: str |> String.replace_invalid() |> String.replace(~r/[[:cntrl:]]/u, "")
end
