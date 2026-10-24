defmodule HerdrTerm.Client.Term.Theme do
  @moduledoc """
  Resolves the scene's theme tokens to cell styles and picks border glyphs.
  The server never does either; each client owns its look.
  """

  alias HerdrScene.Cell
  alias HerdrTerm.Cells

  @type t :: %{styles: %{atom => Cell.t()}, glyphs: %{atom => binary}}

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
        inverse: Cells.style(attrs: [:inverse])
      },
      glyphs: %{h: "─", v: "│", tl: "┌", tr: "┐", bl: "└", br: "┘"}
    }
  end

  @doc "Style for a token; nil or unknown tokens resolve to `:default`."
  @spec style(t, atom | nil) :: Cell.t()
  def style(%{styles: styles}, token), do: Map.get(styles, token) || Map.fetch!(styles, :default)

  @spec border_style(t, boolean) :: Cell.t()
  def border_style(theme, true), do: style(theme, :focus)
  def border_style(theme, false), do: style(theme, :muted)

  @spec glyphs(t) :: %{atom => binary}
  def glyphs(%{glyphs: glyphs}), do: glyphs
end
