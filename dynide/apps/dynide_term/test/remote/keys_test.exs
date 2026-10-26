defmodule DynideTerm.Remote.KeysTest do
  use ExUnit.Case, async: true

  alias DynideScene.Event
  alias DynideTerm.Remote.Keys

  @cb Event.key("b", [:ctrl])

  defp run(events) do
    {acts, _} = Enum.map_reduce(events, Keys.new(), &Keys.filter(&2, &1))
    acts
  end

  test "table" do
    assert run([@cb, Event.key("q")]) == [:swallow, :detach]
    assert run([@cb, @cb]) == [:swallow, :forward]
    assert run([@cb, Event.key("x")]) == [:swallow, {:forward, [@cb, Event.key("x")]}]
    assert run([Event.key("q")]) == [:forward]
    assert run([@cb, Event.key("q"), Event.key("q")]) == [:swallow, :detach, :forward]
    # anything but a key press passes through and keeps the prefix
    assert run([@cb, {:paste, "hi"}, Event.key("q")]) == [:swallow, :forward, :detach]

    assert run([@cb, Event.key("b", [:ctrl], event: :release), Event.key("q")]) ==
             [:swallow, :forward, :detach]
  end
end
