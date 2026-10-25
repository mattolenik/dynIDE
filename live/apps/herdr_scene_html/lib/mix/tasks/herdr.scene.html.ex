defmodule Mix.Tasks.Herdr.Scene.Html do
  @shortdoc "Renders golden scene fixtures to HTML"
  @moduledoc """
  `mix herdr.scene.html [NAME ... | --all] [--out DIR]`

  Writes `<name>.html` per fixture plus `index.html`. `DIR` defaults to
  `_build/scene_html` under the umbrella root.
  """
  use Mix.Task

  alias HerdrScene.Fixture

  @impl Mix.Task
  def run(args) do
    {opts, names} = OptionParser.parse!(args, strict: [all: :boolean, out: :string])
    Mix.Task.run("app.config")

    names = if opts[:all] || names == [], do: Fixture.names(), else: names
    out = opts[:out] || Path.join(umbrella_root(), "_build/scene_html")
    File.mkdir_p!(out)

    for name <- names do
      File.write!(Path.join(out, name <> ".html"), HerdrSceneHtml.render(Fixture.load(name)))
    end

    links = Enum.map(names, &~s(<li><a href="#{&1}.html">#{&1}</a></li>))

    File.write!(Path.join(out, "index.html"), [
      "<!doctype html><title>scenes</title><ul>",
      links,
      "</ul>"
    ])

    Mix.shell().info("wrote #{length(names)} scenes to #{out}")
  end

  defp umbrella_root do
    if Mix.Project.umbrella?(), do: File.cwd!(), else: Path.expand("../..", File.cwd!())
  end
end
