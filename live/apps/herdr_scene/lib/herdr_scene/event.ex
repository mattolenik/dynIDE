defmodule HerdrScene.Event do
  @moduledoc """
  The neutral input vocabulary. Terminal and GUI clients both produce exactly
  these; the server consumes only these.

      {:key, %{key: atom | binary, mods: [atom], event: :press | :release | :repeat, text: binary | nil}}
      {:mouse, %{kind: :press | :release | :move | :drag | :scroll, button: atom, x: n, y: n, mods: [atom], px: {x, y} | nil}}
      {:paste, binary}
      {:focus, boolean}
      {:resize, %{cols: n, rows: n, cell_px: {w, h} | nil}}
      {:chrome, path, action}

  Maps are open: required keys must be valid, unknown extra keys are accepted.
  Mouse `x`/`y` are scene cell coordinates (0-based, the host screen grid,
  which equals `scene.size`); `px` is the optional pixel position.

  `mods` is a sorted, deduplicated subset of `mods/0`. `key` is a named key
  (`named_keys/0`) or a binary of exactly one grapheme.
  """

  @type t :: tuple

  @named [:enter, :tab, :backspace, :escape, :up, :down, :left, :right, :home, :end] ++
           [:page_up, :page_down, :insert, :delete] ++ Enum.map(1..12, &:"f#{&1}")
  @mods [:alt, :caps_lock, :ctrl, :hyper, :meta, :num_lock, :shift, :super]
  @buttons [:left, :middle, :right, :none, :wheel_up, :wheel_down, :wheel_left, :wheel_right]
  @mouse_kinds [:press, :release, :move, :drag, :scroll]
  @key_events [:press, :release, :repeat]

  def named_keys, do: @named
  def mods, do: @mods

  @doc "Builds a normalized key event. Options: `:event` (default `:press`), `:text` (default nil)."
  @spec key(atom | binary, [atom], keyword) :: t
  def key(key, mods \\ [], opts \\ []) do
    {:key,
     %{
       key: key,
       mods: mods |> Enum.uniq() |> Enum.sort(),
       event: Keyword.get(opts, :event, :press),
       text: Keyword.get(opts, :text)
     }}
  end

  @spec validate(term) :: :ok | {:error, binary}
  def validate({:key, %{key: k, mods: m, event: e, text: t}}) do
    cond do
      not valid_key?(k) -> {:error, "key: expected named key or one grapheme, got #{inspect(k)}"}
      e not in @key_events -> {:error, "key.event: unknown #{inspect(e)}"}
      not (is_nil(t) or is_binary(t)) -> {:error, "key.text: expected binary or nil"}
      true -> check_mods(m)
    end
  end

  def validate({:mouse, %{kind: k, button: b, x: x, y: y, mods: m, px: px}}) do
    cond do
      k not in @mouse_kinds -> {:error, "mouse.kind: unknown #{inspect(k)}"}
      b not in @buttons -> {:error, "mouse.button: unknown #{inspect(b)}"}
      not (nat?(x) and nat?(y)) -> {:error, "mouse.x/y: expected non-negative integers"}
      not (is_nil(px) or pair?(px)) -> {:error, "mouse.px: expected {x, y} or nil"}
      true -> check_mods(m)
    end
  end

  def validate({:paste, text}) when is_binary(text), do: :ok
  def validate({:focus, f}) when is_boolean(f), do: :ok

  def validate({:resize, %{cols: c, rows: r, cell_px: px}}) do
    cond do
      not (is_integer(c) and c > 0 and is_integer(r) and r > 0) ->
        {:error, "resize: cols and rows must be positive integers"}

      not (is_nil(px) or pair?(px)) ->
        {:error, "resize.cell_px: expected {w, h} or nil"}

      true ->
        :ok
    end
  end

  def validate({:chrome, path, _action}) when is_list(path), do: :ok
  def validate({:chrome, _, _}), do: {:error, "chrome: path must be a list"}
  def validate(other), do: {:error, "unknown event #{inspect(other)}"}

  defp valid_key?(k) when is_atom(k), do: k in @named
  defp valid_key?(k) when is_binary(k), do: String.valid?(k) and length(String.graphemes(k)) == 1
  defp valid_key?(_), do: false

  defp check_mods(m) when is_list(m) do
    cond do
      Enum.any?(m, &(&1 not in @mods)) -> {:error, "mods: unknown modifier in #{inspect(m)}"}
      m != m |> Enum.uniq() |> Enum.sort() -> {:error, "mods: must be sorted and unique"}
      true -> :ok
    end
  end

  defp check_mods(_), do: {:error, "mods: expected list"}

  defp nat?(n), do: is_integer(n) and n >= 0
  defp pair?({a, b}), do: nat?(a) and nat?(b)
  defp pair?(_), do: false
end
