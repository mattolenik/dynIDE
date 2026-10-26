defmodule DynideScene.EventTest do
  use ExUnit.Case, async: true

  alias DynideScene.Event

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
          {:chrome, [:tabs, {:tab, 1}], {:click, %{x: 3, y: 0}}},
          {:chrome, [:sidebar], {:scroll_down, %{x: 0, y: 0, extra: 1}}}
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
          {:chrome, :notalist, {:click, %{x: 0, y: 0}}},
          {:chrome, [:tabs], {:click, %{x: -1, y: 0}}},
          {:chrome, [:tabs], {:click, %{x: 0}}},
          :junk
        ] do
      assert {:error, msg} = Event.validate(e), inspect(e)
      assert is_binary(msg)
    end
  end

  test "chrome actions" do
    for k <-
          [:click, :double_click, :right_click, :middle_click, :drag, :drop] ++
            [:scroll_up, :scroll_down],
        do: assert(Event.validate({:chrome, [:a], {k, %{x: 0, y: 0}}}) == :ok)

    assert Event.validate({:chrome, [:tabs], :click}) ==
             {:error, "chrome.action: expected {kind, %{x, y}}"}

    assert {:error, msg} = Event.validate({:chrome, [:tabs], {:hover, %{x: 0, y: 0}}})
    assert msg =~ "chrome.action: unknown kind :hover"
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

  test "validate is total and open" do
    for j <- [nil, 1, :x, "s", [], %{}, {}, {:key, :x}, {:mouse, 1}, {:resize, nil}, {:key, %{}}] do
      assert {:error, _} = Event.validate(j)
    end

    assert Event.validate(key(%{extra: 1})) == :ok
    assert Event.validate(mouse(%{extra: 1})) == :ok
  end
end
