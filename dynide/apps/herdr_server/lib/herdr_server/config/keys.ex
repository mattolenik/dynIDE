defmodule HerdrServer.Config.Keys do
  @moduledoc """
  herdr's key syntax (`src/config/keybinds.rs` `parse_key_combo`, inventory §8) to and
  from `%{prefix: boolean, key: binary | atom, mods: [atom]}` (pure).

    * `+`-joined, case-insensitive tokens with surrounding blanks trimmed: modifiers
      `ctrl`/`control`, `alt`/`option`/`meta` (`:alt`), `shift`, `cmd`/`command`/`super`
      (`:super`), and exactly one key. A leading `prefix` means "after the prefix".
    * Keys: one character (an uppercase letter implies shift), `space`, `enter`/`return`,
      `esc`/`escape`, `tab`, `backspace`/`bs`, `up`/`down`/`left`/`right`, `home`, `end`,
      `pageup`/`pagedown`, `insert`, `delete`, `f1`..`f12`, and the punctuation names
      `minus`, `comma`, `period`, `slash`, `backslash`, `quote`, `double_quote`,
      `semicolon`, `colon`, `percent`, `ampersand`, `backtick`, `plus`. `"+"` alone and a
      trailing `"++"` are the plus key.
    * The parsed key and mods are stored as `App.Keybinds.normalize/2` does (`"T"`, no
      `:shift`); mods are sorted. `hyper` and unknown tokens are errors.

  `format/1` is canonical: `prefix` first, modifiers in the order ctrl, alt, shift,
  super, a shifted letter as `shift+<lower>`, and `space`, `minus`, `plus` and the named
  keys by name (other characters as themselves), so `parse(format(k)) == {:ok, k}`.
  """

  alias HerdrServer.App.Keybinds

  @type t :: %{prefix: boolean, key: binary | atom, mods: [atom]}

  @mods %{
    "ctrl" => :ctrl,
    "control" => :ctrl,
    "alt" => :alt,
    "option" => :alt,
    "meta" => :alt,
    "shift" => :shift,
    "cmd" => :super,
    "command" => :super,
    "super" => :super
  }

  @named %{
    "space" => " ",
    "enter" => :enter,
    "return" => :enter,
    "esc" => :escape,
    "escape" => :escape,
    "tab" => :tab,
    "backspace" => :backspace,
    "bs" => :backspace,
    "up" => :up,
    "down" => :down,
    "left" => :left,
    "right" => :right,
    "home" => :home,
    "end" => :end,
    "pageup" => :page_up,
    "pagedown" => :page_down,
    "insert" => :insert,
    "delete" => :delete,
    "minus" => "-",
    "comma" => ",",
    "period" => ".",
    "slash" => "/",
    "backslash" => "\\",
    "quote" => "'",
    "double_quote" => "\"",
    "double-quote" => "\"",
    "semicolon" => ";",
    "colon" => ":",
    "percent" => "%",
    "ampersand" => "&",
    "backtick" => "`",
    "plus" => "+"
  }

  @fkeys Map.new(1..12, &{"f#{&1}", :"f#{&1}"})

  # canonical names for format/1
  @names %{
    " " => "space",
    "-" => "minus",
    "+" => "plus",
    enter: "enter",
    escape: "esc",
    tab: "tab",
    backspace: "backspace",
    up: "up",
    down: "down",
    left: "left",
    right: "right",
    home: "home",
    end: "end",
    page_up: "pageup",
    page_down: "pagedown",
    insert: "insert",
    delete: "delete"
  }

  @order [:ctrl, :alt, :shift, :super]

  @spec parse(term) :: {:ok, t} | {:error, binary}
  def parse(spec) when is_binary(spec) do
    s = String.trim(spec)

    cond do
      s == "+" -> build(false, [], "+")
      String.ends_with?(s, "++") -> plus(String.slice(s, 0..-3//1), spec)
      true -> tokens(String.split(s, "+"), spec)
    end
  end

  def parse(other), do: {:error, "key spec must be a string, got #{inspect(other)}"}

  @spec format(t) :: binary
  def format(%{prefix: prefix, key: key, mods: mods}) do
    {key, mods} = unshift(key, mods)
    mods = Enum.filter(@order, &(&1 in mods)) |> Enum.map(&mod_name/1)
    Enum.join(if(prefix, do: ["prefix"], else: []) ++ mods ++ [key_name(key)], "+")
  end

  # --- parse ---

  defp plus(mods_part, spec) do
    with {:ok, prefix, mods} <- mods_only(String.split(mods_part, "+"), spec),
         do: build(prefix, mods, "+")
  end

  defp mods_only(parts, spec) do
    Enum.reduce_while(Enum.with_index(parts), {:ok, false, []}, fn {p, i}, {:ok, pre, mods} ->
      case token(String.trim(p), i) do
        :prefix -> {:cont, {:ok, true, mods}}
        {:mod, m} -> {:cont, {:ok, pre, [m | mods]}}
        _ -> {:halt, bad(spec)}
      end
    end)
  end

  defp tokens(parts, spec) do
    parts
    |> Enum.with_index()
    |> Enum.reduce_while({false, [], nil}, fn {p, i}, {pre, mods, key} ->
      case token(String.trim(p), i) do
        :prefix -> {:cont, {true, mods, key}}
        {:mod, m} -> {:cont, {pre, [m | mods], key}}
        {:key, k} when key == nil -> {:cont, {pre, mods, k}}
        _ -> {:halt, :error}
      end
    end)
    |> case do
      {pre, mods, key} when key != nil -> build(pre, mods, key)
      _ -> bad(spec)
    end
  end

  # :prefix only as the first token
  defp token("", _i), do: :error

  defp token(t, i) do
    lower = String.downcase(t)

    cond do
      lower == "prefix" and i == 0 -> :prefix
      Map.has_key?(@mods, lower) -> {:mod, @mods[lower]}
      Map.has_key?(@named, lower) -> {:key, @named[lower]}
      Map.has_key?(@fkeys, lower) -> {:key, @fkeys[lower]}
      String.length(t) == 1 -> {:key, t}
      true -> :error
    end
  end

  defp build(prefix, mods, key) do
    {key, mods} = upper(key, mods)
    {key, mods} = Keybinds.normalize(key, mods |> Enum.uniq() |> Enum.sort())
    {:ok, %{prefix: prefix, key: key, mods: mods}}
  end

  # an uppercase letter implies shift
  defp upper(key, mods) when is_binary(key) do
    if key != String.downcase(key), do: {key, [:shift | mods]}, else: {key, mods}
  end

  defp upper(key, mods), do: {key, mods}

  defp bad(spec), do: {:error, "invalid key #{inspect(spec)}"}

  # --- format ---

  defp unshift(key, mods) when is_binary(key) do
    low = String.downcase(key)
    if low != key, do: {low, Enum.uniq([:shift | mods])}, else: {key, mods}
  end

  defp unshift(key, mods), do: {key, mods}

  defp mod_name(m), do: Atom.to_string(m)

  defp key_name(key) do
    case @names do
      %{^key => name} -> name
      _ -> to_string(key)
    end
  end
end
