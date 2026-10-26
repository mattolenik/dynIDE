defmodule Mix.Tasks.DynideTerm.FixtureTextTest do
  # not async: the task runs Mix's app.config, which can change the VM cwd, and async
  # modules start while ExUnit still requires the other test files by relative path
  use ExUnit.Case, async: false

  alias DynideScene.Cell
  alias Mix.Tasks.DynideTerm.FixtureText

  test "encodes a styled cell as SGR" do
    c = %Cell{glyph: "x", fg: {:rgb, 1, 2, 3}, bg: {:palette, 4}, attrs: [:bold, :inverse]}
    assert IO.iodata_to_binary(FixtureText.cell(c)) == "\e[0;1;7;38;2;1;2;3;44mx"
    assert IO.iodata_to_binary(FixtureText.cell(%Cell{})) == "\e[0m "
  end

  @tag :tmp_dir
  test "writes text and ansi for one fixture", %{tmp_dir: dir} do
    name = hd(DynideScene.Fixture.names())
    ExUnit.CaptureIO.capture_io(fn -> FixtureText.run([name, "--out", dir]) end)
    assert File.read!(Path.join(dir, name <> ".txt")) =~ "\n"
    assert File.read!(Path.join(dir, name <> ".ans")) =~ "\e[0m"
  end
end
