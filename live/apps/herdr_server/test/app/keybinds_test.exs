defmodule HerdrServer.App.KeybindsTest do
  use ExUnit.Case, async: true
  alias HerdrServer.App.Keybinds

  defp tables(kb), do: [kb.prefix_binds, kb.direct, kb.resize]

  test "every default MFA is an exported function of the right arity" do
    Code.ensure_loaded!(HerdrServer.App.Actions)

    for t <- tables(Keybinds.default()), {_, {m, f, a}} <- t do
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

  defp has_fun?(f) when is_function(f), do: true
  defp has_fun?(%_{} = s), do: s |> Map.from_struct() |> has_fun?()
  defp has_fun?(m) when is_map(m), do: Enum.any?(m, fn {k, v} -> has_fun?(k) or has_fun?(v) end)
  defp has_fun?(t) when is_tuple(t), do: t |> Tuple.to_list() |> has_fun?()
  defp has_fun?(l) when is_list(l), do: Enum.any?(l, &has_fun?/1)
  defp has_fun?(_), do: false
end
