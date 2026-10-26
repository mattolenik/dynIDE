defmodule Mix.Tasks.Dynide.Api.Docs do
  @shortdoc "Generate docs/herdr-live/api.md from the API spec"

  @moduledoc """
  Writes `docs/herdr-live/api.md` from `DynideServer.Api.Spec`.

      mix dynide.api.docs           # write the file
      mix dynide.api.docs --check   # exit 1 if the file differs
  """
  use Mix.Task

  alias DynideServer.Api.Spec.Doc

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("compile")
    path = Doc.path()
    md = Doc.markdown()

    if "--check" in args do
      if File.read(path) == {:ok, md} do
        Mix.shell().info("api.md is up to date")
      else
        Mix.shell().error("#{path} is stale: run `mix dynide.api.docs`")
        exit({:shutdown, 1})
      end
    else
      File.write!(path, md)
      Mix.shell().info("wrote #{path}")
    end
  end
end
