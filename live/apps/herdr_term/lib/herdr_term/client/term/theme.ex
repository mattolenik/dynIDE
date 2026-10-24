defmodule HerdrTerm.Client.Term.Theme do
  @moduledoc """
  Resolves the scene's theme tokens to cell styles and picks border glyphs.
  The server never does either; each client owns its look.
  """

  alias HerdrScene.Cell
  alias HerdrTerm.Cells

  @type glyphs :: %{atom => binary | %{atom => binary}}
  @type t :: %{styles: %{atom => Cell.t()}, glyphs: glyphs}

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
      }
    }
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
