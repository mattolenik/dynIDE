defmodule HerdrServer.Config.KeysTest do
  use ExUnit.Case, async: true

  alias HerdrServer.Config.Keys

  test "canonical specs round trip" do
    for s <-
          ~w(ctrl+b prefix+shift+t prefix+minus prefix+? f5 alt+enter prefix+tab prefix+shift+tab) ++
            ~w(prefix+space super+k prefix+1 prefix+plus ctrl+alt+x prefix+ctrl+left esc f12) do
      assert {:ok, k} = Keys.parse(s), s
      assert Keys.format(k) == s
    end
  end

  test "parsed form matches Keybinds.normalize/2" do
    assert Keys.parse("prefix+shift+t") == {:ok, %{prefix: true, key: "T", mods: []}}
    assert Keys.parse("prefix+T") == {:ok, %{prefix: true, key: "T", mods: []}}
    assert Keys.parse("ctrl+b") == {:ok, %{prefix: false, key: "b", mods: [:ctrl]}}
    assert Keys.parse("Control+B") == {:ok, %{prefix: false, key: "B", mods: [:ctrl]}}
    assert Keys.parse("prefix+shift+tab") == {:ok, %{prefix: true, key: :tab, mods: [:shift]}}
    assert Keys.parse("shift+1") == {:ok, %{prefix: false, key: "1", mods: [:shift]}}
  end

  test "aliases and named keys" do
    for {alias_spec, canonical} <- [
          {"option+x", "alt+x"},
          {"meta+x", "alt+x"},
          {"cmd+k", "super+k"},
          {"command+k", "super+k"},
          {"prefix+-", "prefix+minus"},
          {"prefix+return", "prefix+enter"},
          {"escape", "esc"},
          {"prefix+comma", "prefix+,"},
          {"+", "plus"},
          {"ctrl++", "ctrl+plus"},
          {" prefix + v ", "prefix+v"},
          {"bs", "backspace"}
        ] do
      assert {:ok, k} = Keys.parse(alias_spec), alias_spec
      assert Keys.format(k) == canonical, alias_spec
    end

    assert {:ok, %{key: ","}} = Keys.parse("comma")
    assert {:ok, %{key: "\\"}} = Keys.parse("backslash")
    assert {:ok, %{key: "'"}} = Keys.parse("quote")
    assert {:ok, %{key: ";"}} = Keys.parse("semicolon")
    assert {:ok, %{key: ":"}} = Keys.parse("colon")
    assert {:ok, %{key: "/"}} = Keys.parse("slash")
    assert {:ok, %{key: "."}} = Keys.parse("period")
    assert {:ok, %{key: :f1}} = Keys.parse("F1")
    assert {:ok, %{key: :up}} = Keys.parse("up")
  end

  test "bad specs are errors" do
    for s <- ["hyper+q", "", "ctrl+", "a+b", "prefix", "prefix+prefix+x", "f13", "ctrl+foo", 3] do
      assert {:error, msg} = Keys.parse(s), inspect(s)
      assert is_binary(msg)
    end
  end
end
