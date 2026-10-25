defmodule HerdrServer.Client.OutboxTest do
  use ExUnit.Case, async: true

  alias HerdrScene.Protocol
  alias HerdrScene.Scene.Pane
  alias HerdrServer.Client.Outbox

  defp scene(rows_by_pane) do
    base = HerdrScene.Fixture.load("two_pane_split_120x40")

    panes =
      base.panes
      |> Enum.zip(rows_by_pane)
      |> Enum.map(fn {%Pane{} = p, rows} -> %Pane{p | rows: {:inline, rows}} end)

    %{base | panes: panes}
  end

  defp ids(s), do: Enum.map(s.panes, & &1.id)
  defp inline(%{panes: panes}, i), do: elem(Enum.at(panes, i).rows, 1)

  defp valid!(msgs), do: for(m <- msgs, do: assert(:ok = Protocol.validate_server_msg(m)))

  defp flushed(t, msg) do
    {msgs, t} = t |> Outbox.put(msg) |> Outbox.flush()
    {msgs, t}
  end

  test "first scene sends all rows inline; same scene with one change sends one row" do
    s1 = scene([[{0, "a"}, {1, "b"}], [{0, "x"}]])
    {[{:scene, out}] = msgs, t} = flushed(Outbox.new(), {:scene, s1})
    valid!(msgs)
    assert inline(out, 0) == [{0, "a"}, {1, "b"}]
    assert inline(out, 1) == [{0, "x"}]
    refute Outbox.pending?(t)

    s2 = scene([[{0, "a"}, {1, "B"}], [{0, "x"}]])
    {[{:scene, out}] = msgs, _} = flushed(t, {:scene, s2})
    valid!(msgs)
    assert inline(out, 0) == [{1, "B"}]
    assert inline(out, 1) == []
  end

  test "rows message shows only changed rows; two coalesce" do
    s = scene([[{0, "a"}, {1, "b"}], [{0, "x"}]])
    [p1, _] = ids(s)
    {_, t} = flushed(Outbox.new(), {:scene, s})

    t = Outbox.put(t, {:rows, p1, 3, [{0, "A"}, {1, "b"}]})
    assert Outbox.pending?(t)
    t = Outbox.put(t, {:rows, p1, 4, [{5, "n"}]})
    {msgs, t} = Outbox.flush(t)
    valid!(msgs)
    assert msgs == [{:rows, p1, 4, [{0, "A"}, {5, "n"}]}]
    assert {[], _} = Outbox.flush(t)
    refute Outbox.pending?(t)
  end

  test "rows for a pane absent from the last scene produce nothing" do
    s = scene([[{0, "a"}], [{0, "x"}]])
    {_, t} = flushed(Outbox.new(), {:scene, s})
    {msgs, t} = flushed(t, {:rows, 9999, 1, [{0, "z"}]})
    assert msgs == []
    refute Outbox.pending?(t)
  end

  test "rows for a pane absent from the last scene are not pending" do
    s = scene([[{0, "a"}], [{0, "x"}]])
    {_, t} = flushed(Outbox.new(), {:scene, s})
    refute Outbox.pending?(Outbox.put(t, {:rows, 9999, 1, [{0, "z"}]}))
    refute Outbox.pending?(Outbox.put(Outbox.new(), {:rows, 1, 1, [{0, "z"}]}))
  end

  test "scene pending plus rows for a pane not in it: only the scene" do
    s = scene([[{0, "a"}], [{0, "x"}]])
    t = Outbox.new() |> Outbox.put({:scene, s}) |> Outbox.put({:rows, 9999, 1, [{0, "z"}]})
    {msgs, t} = Outbox.flush(t)
    assert [{:scene, _}] = msgs
    assert Map.keys(t.rows) |> Enum.sort() == Enum.sort(ids(s))
  end

  test "full resends every row, including newer rows" do
    s = scene([[{0, "a"}, {1, "b"}], [{0, "x"}]])
    [p1, _] = ids(s)
    {_, t} = flushed(Outbox.new(), {:scene, s})
    {_, t} = flushed(t, {:rows, p1, 1, [{0, "A"}]})
    {[{:scene, out}] = msgs, t} = Outbox.full(t)
    valid!(msgs)
    assert inline(out, 0) == [{0, "A"}, {1, "b"}]
    assert inline(out, 1) == [{0, "x"}]
    refute Outbox.pending?(t)
  end

  test "a pane removed from the scene and re-added is sent in full" do
    s = scene([[{0, "a"}], [{0, "x"}]])
    {_, t} = flushed(Outbox.new(), {:scene, s})
    one = %{s | panes: [hd(s.panes)]}
    {_, t} = flushed(t, {:scene, one})
    assert Map.keys(t.sent) == [hd(ids(s))]

    {[{:scene, out}], _} = flushed(t, {:scene, s})
    assert inline(out, 1) == [{0, "x"}]
  end
end
