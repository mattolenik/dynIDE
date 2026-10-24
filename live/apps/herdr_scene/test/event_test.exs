defmodule HerdrScene.EventTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Event

  defp key(over \\ %{}),
    do: {:key, Map.merge(%{key: "a", mods: [], event: :press, text: nil}, over)}

  defp mouse(over \\ %{}),
    do: {:mouse, Map.merge(%{kind: :press, button: :left, x: 1, y: 2, mods: [], px: nil}, over)}

  test "valid examples" do
    for e <- [
          key(),
          key(%{key: :enter, mods: [:ctrl, :shift], event: :repeat, text: "a"}),
          key(%{key: :f12}),
          key(%{key: "é"}),
          mouse(),
          mouse(%{kind: :scroll, button: :wheel_up, px: {3, 4}}),
          {:paste, "hello"},
          {:focus, true},
          {:resize, %{cols: 80, rows: 24, cell_px: {8, 16}}},
          {:resize, %{cols: 80, rows: 24, cell_px: nil}},
          {:chrome, [:tabs, 1], :click}
        ] do
      assert Event.validate(e) == :ok, inspect(e)
    end
  end

  test "invalid examples" do
    for e <- [
          key(%{mods: [:shift, :ctrl]}),
          key(%{mods: [:ctrl, :ctrl]}),
          key(%{mods: [:bogus]}),
          key(%{key: "ab"}),
          key(%{key: ""}),
          key(%{key: :f13}),
          key(%{event: :tap}),
          mouse(%{button: :banana}),
          mouse(%{kind: :hover}),
          mouse(%{x: -1}),
          {:paste, 1},
          {:focus, :yes},
          {:resize, %{cols: 0, rows: 24, cell_px: nil}},
          {:chrome, :notalist, :click},
          :junk
        ] do
      assert {:error, msg} = Event.validate(e), inspect(e)
      assert is_binary(msg)
    end
  end

  test "key/3 normalizes" do
    assert {:key, %{key: "a", mods: [:ctrl, :shift], event: :press, text: nil}} =
             Event.key("a", [:shift, :ctrl, :shift])

    assert {:key, %{event: :release, text: "a"}} = Event.key("a", [], event: :release, text: "a")
  end

  test "named keys" do
    assert :f1 in Event.named_keys() and :f12 in Event.named_keys()
    assert Event.mods() == Enum.sort(Event.mods())
  end
end
