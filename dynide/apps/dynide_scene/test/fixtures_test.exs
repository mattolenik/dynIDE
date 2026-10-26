defmodule DynideScene.FixturesTest do
  use ExUnit.Case, async: true

  alias DynideScene.{Fixture, Scene}

  test "every fixture validates" do
    for name <- Fixture.names(), do: assert(Scene.validate(Fixture.load(name)) == :ok)
  end

  @tag :tmp_dir
  test "dump/load round trip", %{tmp_dir: dir} do
    scene = DynideScene.SceneSample.build()
    assert Fixture.dump("sample", scene, dir) == :ok
    assert File.read!(Path.join(dir, "sample.exs")) |> String.ends_with?("\n")
    assert Fixture.load("sample", dir) == scene
    assert Fixture.names(dir) == ["sample"]
  end

  test "dir exists" do
    assert File.dir?(Fixture.dir())
  end
end
