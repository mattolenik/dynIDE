defmodule HerdrServer.Client.KeysTest do
  use ExUnit.Case, async: true
  alias HerdrScene.Event
  alias HerdrServer.App.{Actions, Keybinds}
  alias HerdrServer.Client.Keys

  @kb Keybinds.default()
  @pfx Event.key("b", [:ctrl])

  defp fresh, do: %{mode: :terminal, swallow: MapSet.new()}
  defp key(st, k, opts \\ []), do: Keys.resolve(st, @kb, ev(k, opts))

  defp ev(k, opts) do
    {key, mods} = if is_tuple(k), do: k, else: {k, []}
    Event.key(key, mods, opts)
  end

  defp keys(st, ks), do: Enum.reduce(ks, {st, nil}, fn k, {s, _} -> key(s, k) end)

  test "typing forwards; prefix enters prefix mode; prefix twice forwards the prefix key" do
    a = Event.key("a")
    assert {%{mode: :terminal}, {:forward, ^a}} = key(fresh(), "a")
    assert {%{mode: :prefix} = st, :consumed} = Keys.resolve(fresh(), @kb, @pfx)
    assert {%{mode: :terminal}, {:forward, @pfx}} = Keys.resolve(st, @kb, @pfx)
  end

  test "a bound key in prefix mode runs its action and returns to terminal" do
    assert {%{mode: :terminal}, {:run, {Actions, :split, [:horizontal]}}} =
             keys(fresh(), [{"b", [:ctrl]}, "v"])

    assert {%{mode: :terminal}, {:run, {HerdrServer.App.Modal.Confirm, :close_tab, []}}} =
             keys(fresh(), [{"b", [:ctrl]}, {"X", [:shift]}])
  end

  test "an unbound key in prefix mode returns to terminal and is consumed" do
    assert {%{mode: :terminal}, :consumed} = keys(fresh(), [{"b", [:ctrl]}, "y"])
  end

  test "resize mode: enter, bound keys run, unbound stay, escape/enter exit" do
    {st, :consumed} = keys(fresh(), [{"b", [:ctrl]}, "r"])
    assert st.mode == :resize
    assert {%{mode: :resize}, {:run, {Actions, :resize_dir, [:left, 0.05]}}} = key(st, "h")
    assert {%{mode: :resize}, :consumed} = key(st, "q")
    assert {%{mode: :terminal}, :consumed} = key(st, :escape)
    assert {%{mode: :terminal}, :consumed} = key(st, :enter)
  end

  test "releases in non-terminal modes are dropped" do
    {st, :consumed} = Keys.resolve(fresh(), @kb, @pfx)
    assert {^st, :consumed} = key(st, "c", event: :release)
  end

  test "release of a consumed press is swallowed; release of a forwarded press is not" do
    {st, {:run, _}} = keys(fresh(), [{"b", [:ctrl]}, "v"])
    {st, :consumed} = key(st, "v", event: :release)
    {st, :consumed} = key(st, {"b", [:ctrl]}, event: :release)
    assert st.swallow == MapSet.new()
    {st, {:forward, _}} = key(st, "a")
    rel = Event.key("a", [], event: :release)
    assert {_, {:forward, ^rel}} = Keys.resolve(st, @kb, rel)
  end

  test "a stale swallow entry never eats a later legitimate release" do
    {st, _} = keys(fresh(), [{"b", [:ctrl]}, "z"])
    {st, {:forward, _}} = key(st, "z")
    rel = Event.key("z", [], event: :release)
    assert {_, {:forward, ^rel}} = Keys.resolve(st, @kb, rel)
  end

  test "release with different modifiers than the consumed press is swallowed" do
    {st, _} = keys(fresh(), [{"b", [:ctrl]}, "v"])
    assert {_, :consumed} = key(st, {"v", [:ctrl]}, event: :release)
    {st, _} = keys(fresh(), [{"b", [:ctrl]}, {"X", [:shift]}])
    assert {_, :consumed} = key(st, "x", event: :release)
  end

  test "prefix [ enters copy mode; copy mode consumes presses and their releases" do
    assert {%{mode: :copy} = st, :consumed} = keys(fresh(), [{"b", [:ctrl]}, "["])
    assert {%{mode: :copy} = st, :consumed} = key(st, "j")
    assert MapSet.member?(st.swallow, "j")
    assert {%{mode: :copy} = st, :consumed} = key(st, "q")
    st = Keys.enter_mode(st, :terminal)
    assert {%{mode: :terminal}, :consumed} = key(st, "q", event: :release)
  end
end
