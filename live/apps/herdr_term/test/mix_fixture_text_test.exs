defmodule Mix.Tasks.HerdrTerm.FixtureTextTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Cell
  alias Mix.Tasks.HerdrTerm.FixtureText

  test "encodes a styled cell as SGR" do
    c = %Cell{glyph: "x", fg: {:rgb, 1, 2, 3}, bg: {:palette, 4}, attrs: [:bold, :inverse]}
    assert IO.iodata_to_binary(FixtureText.cell(c)) == "\e[0;1;7;38;2;1;2;3;44mx"
    assert IO.iodata_to_binary(FixtureText.cell(%Cell{})) == "\e[0m "
  end

  @tag :tmp_dir
  test "writes text and ansi for one fixture", %{tmp_dir: dir} do
    name = hd(HerdrScene.Fixture.names())
    ExUnit.CaptureIO.capture_io(fn -> FixtureText.run([name, "--out", dir]) end)
    assert File.read!(Path.join(dir, name <> ".txt")) =~ "\n"
    assert File.read!(Path.join(dir, name <> ".ans")) =~ "\e[0m"
  end
end
