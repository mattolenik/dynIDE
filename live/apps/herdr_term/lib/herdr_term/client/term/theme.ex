defmodule HerdrTerm.Client.Term.Theme do
  @moduledoc """
  Resolves the scene's theme tokens to cell styles and picks border glyphs.
  The server never does either; each client owns its look.
  """

  alias HerdrScene.Cell
  alias HerdrTerm.Cells
  alias HerdrTerm.Client.Term.Theme.Palettes

  @type rgb :: {0..255, 0..255, 0..255}
  @type glyphs :: %{atom => binary | %{atom => binary}}
  @typedoc "`host`: the host terminal's default colours, nil until it answers OSC 10/11."
  @type t :: %{styles: %{atom => Cell.t()}, glyphs: glyphs, host: %{fg: rgb | nil, bg: rgb | nil}}

  # badge glyphs per agent state (inventory §2), for `indicators: :dots | :symbols`
  @state_dots %{blocked: "●", done: "●", working: "●", idle: "○", unknown: "·"}
  @state_symbols %{blocked: "×", done: "✓", working: "◐", idle: "○", unknown: "·"}

  @spec default() :: t
  def default do
    %{
      styles: %{
        default: Cells.style([]),
        accent: Cells.style(fg: {:palette, 4}, attrs: [:bold]),
        muted: Cells.style(attrs: [:faint]),
        focus: Cells.style(fg: {:palette, 2}),
        warning: Cells.style(fg: {:palette, 3}),
        error: Cells.style(fg: {:palette, 1}),
        inverse: Cells.style(attrs: [:inverse]),
        success: Cells.style(fg: {:palette, 2}),
        info: Cells.style(fg: {:palette, 6}),
        strong: Cells.style(attrs: [:bold]),
        # tab bar: panel bg on accent (active), overlay0 on surface0 (others)
        selected: Cells.style(fg: {:palette, 0}, bg: {:palette, 4}),
        surface: Cells.style(fg: {:palette, 7}, bg: {:palette, 8})
      },
      glyphs: %{
        h: "─",
        v: "│",
        tl: "┌",
        tr: "┐",
        bl: "└",
        br: "┘",
        edge: "│",
        collapse: "«",
        expand: "»",
        bullet: "●",
        hollow: "○",
        dot: "·",
        sep: " · ",
        cursor: "▸",
        check: "✓",
        enter: "↵",
        ellipsis: "…",
        rule: "─",
        tree_mid: "├─",
        tree_end: "└─",
        state_dots: @state_dots,
        state_symbols: @state_symbols
      },
      host: %{fg: nil, bg: nil}
    }
  end

  @doc """
  The theme for the scene's root `theme` props and the host appearance. With
  `auto_switch` the `light`/`dark` name is picked by `appearance` (nil is dark),
  else `name`; unknown names give catppuccin; nil props give `default/0`.
  """
  @spec for_scene(map | nil, :dark | :light | nil) :: t
  def for_scene(nil, _appearance), do: default()

  def for_scene(props, appearance) when is_map(props) do
    name =
      if props[:auto_switch],
        do: if(appearance == :light, do: props[:light], else: props[:dark]),
        else: props[:name]

    resolve(Palettes.get(name))
  end

  @doc "Token styles built from a palette (slot map); glyphs are the shared set."
  @spec resolve(map) :: t
  def resolve(p) do
    %{
      default()
      | styles: %{
          default: Cells.style(fg: p.text),
          accent: Cells.style(fg: p.accent, attrs: [:bold]),
          muted: Cells.style(fg: p.overlay0),
          focus: Cells.style(fg: p.accent),
          warning: Cells.style(fg: p.yellow),
          error: Cells.style(fg: p.red),
          inverse: Cells.style(attrs: [:inverse]),
          success: Cells.style(fg: p.green),
          info: Cells.style(fg: p.teal),
          strong: Cells.style(fg: p.text, attrs: [:bold]),
          selected: Cells.style(fg: p.panel_bg, bg: p.accent),
          surface: Cells.style(fg: p.text, bg: p.surface0)
        }
    }
  end

  @doc """
  `Cells.restyle/4` changes for a selection, as herdr draws it: with a known host bg,
  a reset style whose bg is that bg mixed 28% toward white (dark host, relative
  luminance below 0.5) or black (light host) and whose fg is black or white,
  whichever contrasts more; otherwise inverse.
  """
  @spec selection_changes(t) :: keyword
  def selection_changes(theme) do
    case theme |> Map.get(:host, %{}) |> Map.get(:bg) do
      {_, _, _} = bg ->
        target = if luminance(bg) < 0.5, do: {255, 255, 255}, else: {0, 0, 0}
        {r, g, b} = sel = mix(bg, target, 0.28)
        l = luminance(sel)

        fg =
          if (l + 0.05) / 0.05 > 1.05 / (l + 0.05),
            do: {:rgb, 0, 0, 0},
            else: {:rgb, 255, 255, 255}

        [fg: fg, bg: {:rgb, r, g, b}, ul: :default, attrs: [], underline: :none]

      nil ->
        [add_attrs: [:inverse]]
    end
  end

  defp mix({r, g, b}, {tr, tg, tb}, k),
    do: {round(r + (tr - r) * k), round(g + (tg - g) * k), round(b + (tb - b) * k)}

  defp luminance({r, g, b}), do: 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)

  defp lin(v) do
    v = v / 255
    if v <= 0.03928, do: v / 12.92, else: :math.pow((v + 0.055) / 1.055, 2.4)
  end

  @doc "Style for a token; nil or unknown tokens resolve to `:default`."
  @spec style(t, atom | nil) :: Cell.t()
  def style(%{styles: styles}, token), do: Map.get(styles, token) || Map.fetch!(styles, :default)

  @spec border_style(t, boolean) :: Cell.t()
  def border_style(theme, true), do: style(theme, :focus)
  def border_style(theme, false), do: style(theme, :muted)

  @spec glyphs(t) :: glyphs
  def glyphs(%{glyphs: glyphs}), do: glyphs
end
