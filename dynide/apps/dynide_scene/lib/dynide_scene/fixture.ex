defmodule DynideScene.Fixture do
  @moduledoc """
  Golden scene fixtures: `priv/fixtures/scenes/<name>.exs` holding the
  `inspect/2` form of a `DynideScene.Scene`, evaluated back by `load/1`.
  """

  @inspect_opts [pretty: true, limit: :infinity, printable_limit: :infinity]

  @spec dir() :: Path.t()
  def dir do
    Application.app_dir(:dynide_scene, "priv/fixtures/scenes")
  rescue
    ArgumentError -> Path.expand("../../priv/fixtures/scenes", __DIR__)
  end

  @spec names(Path.t()) :: [binary]
  def names(dir \\ dir()) do
    dir
    |> Path.join("*.exs")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".exs"))
    |> Enum.sort()
  end

  @spec load(binary, Path.t()) :: DynideScene.Scene.t()
  def load(name, dir \\ dir()) do
    {scene, _binding} = dir |> Path.join(name <> ".exs") |> Code.eval_file()
    scene
  end

  @doc "`dump/2` writes into `dir/0`; `dump/3` takes an explicit directory."
  @spec dump(binary, DynideScene.Scene.t(), Path.t()) :: :ok
  def dump(name, scene, dir \\ dir()) do
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name <> ".exs"), inspect(scene, @inspect_opts) <> "\n")
  end
end
