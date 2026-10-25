defmodule Mix.Tasks.HerdrTerm.FixtureText do
  @shortdoc "Renders golden scene fixtures to plain text and ANSI"
  @moduledoc """
  `mix herdr_term.fixture_text [NAME ... | --all] [--out DIR] [--theme NAME] [--light]`

  Composes each fixture like the terminal client does (pane content is blank)
  and writes `<name>.txt` (cell text per row) and `<name>.ans` (truecolor SGR,
  `cat` it). The theme follows the fixture's root theme props; `--theme`
  forces a palette, `--light` sets the host appearance to light. `DIR`
  defaults to `_build/fixture_text` under the umbrella root.
  """
  use Mix.Task

  alias HerdrScene.{Cell, Fixture}
  alias HerdrTerm.Cells
  alias HerdrTerm.Client.Term.Render.Compose
  alias HerdrTerm.Client.Term.Theme
  alias HerdrTerm.Client.Term.Theme.Palettes

  @sgr_attrs [bold: 1, faint: 2, italic: 3, blink: 5, inverse: 7, invisible: 8, strikethrough: 9]

  @impl Mix.Task
  def run(args) do
    {opts, names} =
      OptionParser.parse!(args,
        strict: [all: :boolean, out: :string, theme: :string, light: :boolean]
      )

    Mix.Task.run("app.config")
    names = if opts[:all] || names == [], do: Fixture.names(), else: names
    out = opts[:out] || Path.join(umbrella_root(), "_build/fixture_text")
    File.mkdir_p!(out)

    for name <- names do
      frame = frame(Fixture.load(name), opts)
      File.write!(Path.join(out, name <> ".txt"), text(frame))
      File.write!(Path.join(out, name <> ".ans"), ansi(frame))
    end

    Mix.shell().info("wrote #{length(names)} screens to #{out}")
  end

  @doc "The composed frame for a scene under the theme the client would pick."
  def frame(scene, opts \\ []) do
    appearance = if opts[:light], do: :light, else: :dark
    props = scene.chrome && scene.chrome.props[:theme]

    theme =
      if opts[:theme],
        do: Theme.resolve(Palettes.get(opts[:theme])),
        else: Theme.for_scene(props, appearance)

    Compose.frame(scene, %{}, theme)
  end

  @spec text([{non_neg_integer, binary}]) :: binary
  def text(frame), do: Enum.map_join(frame, fn {_, row} -> Cells.to_text(row) <> "\n" end)

  @spec ansi([{non_neg_integer, binary}]) :: iodata
  def ansi(frame) do
    Enum.map(frame, fn {_, row} ->
      [for(c <- Cell.decode_row(row), c.width != 0, do: cell(c)), "\e[0m\n"]
    end)
  end

  @doc "SGR-prefixed glyph for one cell."
  @spec cell(Cell.t()) :: iodata
  def cell(%Cell{glyph: g} = c), do: [sgr(c), if(g == "", do: " ", else: g)]

  defp sgr(c) do
    codes =
      [0] ++
        for({a, n} <- @sgr_attrs, a in c.attrs, do: n) ++
        underline(c.underline) ++ color(c.fg, 30) ++ color(c.bg, 40)

    ["\e[", Enum.join(codes, ";"), "m"]
  end

  defp underline(:none), do: []
  defp underline(:double), do: [21]
  defp underline(_), do: [4]

  defp color(:default, _), do: []
  defp color({:palette, n}, base) when n < 8, do: [base + n]
  defp color({:palette, n}, base) when n < 16, do: [base + 60 + n - 8]
  defp color({:palette, n}, base), do: [base + 8, 5, n]
  defp color({:rgb, r, g, b}, base), do: [base + 8, 2, r, g, b]

  defp umbrella_root do
    if Mix.Project.umbrella?(), do: File.cwd!(), else: Path.expand("../..", File.cwd!())
  end
end
