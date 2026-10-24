defmodule HerdrServer.Api.KeysTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Event
  alias HerdrServer.Api.Keys

  defp ok(s), do: (fn {:ok, ev} -> ev end).(Keys.parse(s))

  test "combos and names" do
    assert ok("ctrl+c") == Event.key("c", [:ctrl])
    assert ok("C-c") == Event.key("c", [:ctrl])
    assert ok("c-c") == Event.key("c", [:ctrl])
    assert ok("control+j") == Event.key("j", [:ctrl])
    assert ok("shift+tab") == Event.key(:tab, [:shift])
    assert ok("esc") == Event.key(:escape)
    assert ok("Escape") == Event.key(:escape)
    assert ok("f1") == Event.key(:f1)
    assert ok("minus") == Event.key("-", [], text: "-")
    assert ok("a") == Event.key("a", [], text: "a")
    assert ok("alt+x") == Event.key("x", [:alt])
    assert ok("M-x") == Event.key("x", [:alt])
    assert ok("ctrl+alt+Delete") == Event.key(:delete, [:alt, :ctrl])
    assert ok("PageUp") == Event.key(:page_up)
    assert ok("space") == Event.key(" ", [], text: " ")
    assert ok("+") == Event.key("+", [], text: "+")
    assert ok("ctrl++") == Event.key("+", [:ctrl])
  end

  test "errors" do
    for bad <- ["ctrl+", "bogus", "f13", "", "ctrl+bogus", "hyper+a"],
        do: assert({:error, _} = Keys.parse(bad), bad)
  end
end
