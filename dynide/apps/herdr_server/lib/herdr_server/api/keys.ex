defmodule HerdrServer.Api.Keys do
  @moduledoc """
  Parses herdr key-combo syntax (`"ctrl+c"`, `"C-c"`, `"shift+tab"`, `"f5"`, `"a"`) into
  `HerdrScene.Event` key events. Names and modifiers are case-insensitive; modifiers
  are `ctrl`/`control`, `alt`/`meta`, `shift`, `super`, joined with `+`; the legacy
  `C-x` and `M-x` forms mean ctrl and alt. A bare `+` is the plus key.
  """

  alias HerdrScene.Event

  @named %{
    "enter" => :enter,
    "return" => :enter,
    "tab" => :tab,
    "esc" => :escape,
    "escape" => :escape,
    "backspace" => :backspace,
    "up" => :up,
    "down" => :down,
    "left" => :left,
    "right" => :right,
    "home" => :home,
    "end" => :end,
    "pageup" => :page_up,
    "page_up" => :page_up,
    "pagedown" => :page_down,
    "page_down" => :page_down,
    "insert" => :insert,
    "delete" => :delete
  }
  @fkeys Map.new(1..12, &{"f#{&1}", :"f#{&1}"})
  @chars %{
    "space" => " ",
    "minus" => "-",
    "plus" => "+",
    "backtick" => "`",
    "comma" => ",",
    "period" => ".",
    "slash" => "/",
    "backslash" => "\\",
    "semicolon" => ";",
    "quote" => "'",
    "equal" => "=",
    "lbracket" => "[",
    "rbracket" => "]"
  }
  @mods %{
    "ctrl" => :ctrl,
    "control" => :ctrl,
    "alt" => :alt,
    "meta" => :alt,
    "shift" => :shift,
    "super" => :super
  }

  @spec parse(String.t()) :: {:ok, Event.t()} | {:error, String.t()}
  def parse(str) when is_binary(str) do
    with {mods, key} <- split(str),
         {:ok, k, text} <- key(key, mods) do
      {:ok, Event.key(k, mods, text: text)}
    else
      {:error, _} = e -> e
      _ -> {:error, "invalid key #{inspect(str)}"}
    end
  end

  # {mods, key-name} or :error
  defp split(str) do
    cond do
      str == "" ->
        :error

      String.length(str) == 1 ->
        {[], str}

      m = Regex.run(~r/\A([cCmM])-(.+)\z/su, str) ->
        legacy(m)

      String.ends_with?(str, "++") ->
        combo(String.slice(str, 0..-3//1), "+")

      true ->
        str
        |> String.split("+")
        |> Enum.split(-1)
        |> then(fn {m, [k]} -> combo(Enum.join(m, "+"), k) end)
    end
  end

  defp legacy([_, p, k]), do: {[if(String.downcase(p) == "c", do: :ctrl, else: :alt)], k}

  defp combo(mods, key) do
    names = if mods == "", do: [], else: String.split(mods, "+")
    parsed = Enum.map(names, &Map.get(@mods, String.downcase(&1)))
    if key == "" or nil in parsed, do: :error, else: {parsed, key}
  end

  defp key(name, mods) do
    low = String.downcase(name)

    cond do
      k = @named[low] -> {:ok, k, nil}
      k = @fkeys[low] -> {:ok, k, nil}
      c = @chars[low] -> {:ok, c, text(c, mods)}
      String.length(name) == 1 -> {:ok, one(name, mods), text(name, mods)}
      true -> {:error, "unknown key #{inspect(name)}"}
    end
  end

  # ctrl/alt combos name the base key in lower case
  defp one(c, mods), do: if(:ctrl in mods or :alt in mods, do: String.downcase(c), else: c)
  defp text(c, mods), do: if(mods == [], do: c)
end
