defmodule DynideServer.App.KeybindsTest do
  use ExUnit.Case, async: true
  alias DynideServer.App.{Actions, Keybinds}
  alias DynideServer.App.Keybinds.Catalog
  alias DynideServer.App.Modal.Keybinds, as: KeybindsModal
  alias DynideServer.App.Modal.{Prompt, Settings}
  alias DynideServer.Config.Keys

  defp tables(kb), do: [kb.prefix_binds, kb.direct, kb.resize]

  test "every default MFA is an exported function of the right arity" do
    for t <- tables(Keybinds.default()), {_, {m, f, a}} <- t do
      Code.ensure_loaded!(m)
      assert function_exported?(m, f, length(a) + 1), "#{f}/#{length(a) + 1}"
    end
  end

  test "no funs anywhere in the table" do
    refute has_fun?(Keybinds.default())
  end

  test "normalize and intercept_set" do
    assert Keybinds.normalize("x", [:shift]) == {"X", []}
    assert Keybinds.normalize(:tab, [:shift]) == {:tab, [:shift]}
    assert Keybinds.normalize("1", [:shift]) == {"1", [:shift]}
    assert MapSet.member?(Keybinds.intercept_set(Keybinds.default()), {"b", [:ctrl]})
  end

  test "? opens the keybinds modal and s the settings" do
    kb = Keybinds.default()
    assert Keybinds.lookup(kb, :prefix, {"?", []}) == {KeybindsModal, :open, []}
    assert Keybinds.lookup(kb, :prefix, {"s", []}) == {Settings, :open, []}
  end

  test "catalog: herdr names, groups and defaults match the default tables" do
    kb = Keybinds.default()
    entries = Catalog.entries()
    names = Enum.map(entries, & &1.action)
    assert names == Enum.uniq(names)

    assert Enum.uniq(Enum.map(entries, & &1.group)) == [
             "global",
             "navigation",
             "workspaces / tabs",
             "panes"
           ]

    for e <- entries, spec <- e.default do
      assert {:ok, %{prefix: p, key: k, mods: m}} = Keys.parse(spec)
      assert Keybinds.lookup(kb, if(p, do: :prefix, else: :terminal), {k, m}) == e.mfa, spec
    end

    by = Map.new(entries, &{&1.action, &1})
    assert by["rename_tab"].default == ["prefix+shift+t"]
    assert by["help"].default == ["prefix+?"]
    assert by["split_horizontal"].default == ["prefix+minus"]
    assert by["new_tab"].mfa == {Prompt, :new_tab, []}
    assert by["next_tab"].mfa == {Actions, :next_tab, []}
    assert by["copy_mode"].mfa == {DynideServer.Client.Keys, :enter_mode, [:copy]}
    assert by["copy_mode"].default == ["prefix+["]
  end

  test "to_config lists each action's specs and the prefix" do
    cfg = Keybinds.to_config(Keybinds.default())
    assert cfg["prefix"] == ["ctrl+b"]
    assert cfg["rename_tab"] == ["prefix+shift+t"]
    assert cfg["cycle_pane_previous"] == ["prefix+shift+tab"]
    assert map_size(cfg) == length(Catalog.entries()) + 1
  end

  test "rebind moves an action to a prefix key or a direct key" do
    kb = Keybinds.default()
    rename = {Prompt, :rename_tab, []}
    assert {:ok, kb2} = Keybinds.rebind(kb, "rename_tab", "prefix+t")
    assert Keybinds.lookup(kb2, :prefix, {"t", []}) == rename
    assert Keybinds.lookup(kb2, :prefix, {"T", []}) == nil
    assert Keybinds.to_config(kb2)["rename_tab"] == ["prefix+t"]
    assert Keybinds.intercept_set(kb2) == Keybinds.intercept_set(kb)

    assert {:ok, kb3} = Keybinds.rebind(kb2, "rename_tab", "ctrl+t")
    assert Keybinds.lookup(kb3, :terminal, {"t", [:ctrl]}) == rename
    assert Keybinds.lookup(kb3, :prefix, {"t", []}) == nil
    assert MapSet.member?(Keybinds.intercept_set(kb3), {"t", [:ctrl]})
  end

  test "rebind onto another action's key takes it over" do
    {:ok, kb} = Keybinds.rebind(Keybinds.default(), "rename_tab", "prefix+n")
    assert Keybinds.lookup(kb, :prefix, {"n", []}) == {Prompt, :rename_tab, []}
    assert Keybinds.to_config(kb)["next_tab"] == []
  end

  test "rebind refuses unknown actions, bad specs and the prefix key as a direct bind" do
    kb = Keybinds.default()
    assert {:error, "unknown action" <> _} = Keybinds.rebind(kb, "nope", "prefix+t")
    assert {:error, _} = Keybinds.rebind(kb, "rename_tab", "hyper+t")
    assert {:error, "ctrl+b is the prefix"} = Keybinds.rebind(kb, "rename_tab", "ctrl+b")
  end

  defp has_fun?(f) when is_function(f), do: true
  defp has_fun?(%_{} = s), do: s |> Map.from_struct() |> has_fun?()
  defp has_fun?(m) when is_map(m), do: Enum.any?(m, fn {k, v} -> has_fun?(k) or has_fun?(v) end)
  defp has_fun?(t) when is_tuple(t), do: t |> Tuple.to_list() |> has_fun?()
  defp has_fun?(l) when is_list(l), do: Enum.any?(l, &has_fun?/1)
  defp has_fun?(_), do: false
end
