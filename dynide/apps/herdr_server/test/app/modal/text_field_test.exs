defmodule HerdrServer.App.Modal.TextFieldTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Event
  alias HerdrServer.App.Modal.TextField

  defp keys(f, keys) do
    Enum.reduce(keys, f, fn k, f ->
      case TextField.key(f, key(k)) do
        {:ok, f} -> f
        :ignore -> f
      end
    end)
  end

  defp key({k, mods}), do: Event.key(k, mods)
  defp key(k), do: Event.key(k)

  test "typing, moving and deleting edit at the cursor (graphemes)" do
    f =
      keys(TextField.new(""), ["a", "b", "c", :left, :backspace, "é", :home, :delete, :end, "!"])

    assert f == %{text: "éc!", cursor: 3}
    assert TextField.key(f, Event.key(:up)) == :ignore
    assert TextField.key(f, Event.key("a", [:ctrl])) == :ignore
  end

  test "new puts the cursor at the end; clear empties" do
    assert TextField.new("tab") == %{text: "tab", cursor: 3}
    assert TextField.clear(TextField.new("tab")) == %{text: "", cursor: 0}
  end

  test "names are capped at 64 graphemes; paste drops control characters" do
    long = String.duplicate("x", 70)
    assert TextField.new(long).text == String.duplicate("x", 64)
    f = TextField.insert(TextField.new(String.duplicate("y", 62)), "a\nbcd")
    assert f.text == String.duplicate("y", 62) <> "ab"
    assert f.cursor == 64
    assert keys(f, ["z"]) == f
  end

  test "edge moves are no-ops" do
    f = TextField.new("")
    assert keys(f, [:left, :backspace, :right, :delete]) == f
  end
end
