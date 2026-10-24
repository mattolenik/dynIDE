defmodule HerdrServer.App.StoreFocusTest do
  # Focus-out/in reports when the focused pane changes (fake kernel).
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias HerdrScene.Protocol
  alias HerdrServer.App.{Actions, Store}
  alias HerdrServer.Kernel.Fake
  alias HerdrServer.Pane.{Facts, Rows}

  @size %{cols: 80, rows: 24}

  setup do
    reset()
    on_exit(&reset/0)
    attach()
    assert eventually(fn -> Facts.get(1) != nil end)
    :ok = Store.run({Actions, :split, [:horizontal]}, @size)
    assert eventually(fn -> Facts.get(2) != nil end)
    :ok
  end

  defp reset do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(HerdrServer.Client.Supervisor),
        do: DynamicSupervisor.terminate_child(HerdrServer.Client.Supervisor, pid)

    Store.reset()
  end

  defp attach do
    parent = self()

    pid =
      spawn(fn ->
        info = %{
          kind: :term,
          transport: :ref,
          size: @size,
          cell_px: nil,
          caps: %{},
          client: self()
        }

        send(parent, {:attached, GenServer.call(Protocol.endpoint(), {:attach, info})})
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive {:attached, {:ok, _session, _}}
  end

  defp res(id), do: elem(Fake.Keeper.lookup(Rows.kernel_id(id)), 1)

  defp written(id),
    do: id |> res() |> Map.fetch!(:pty) |> Fake.Pty.writes() |> IO.iodata_to_binary()

  defp eventually(f, n \\ 100) do
    cond do
      f.() -> true
      n == 0 -> false
      true -> Process.sleep(10) && eventually(f, n - 1)
    end
  end

  defp focused, do: Store.snapshot().focus.pane

  test "cycling sends focus-out to the old pane and focus-in to the new one" do
    for id <- [1, 2], do: :ok = Fake.Vt.set_mode(res(id).vt, :focus_events, true)
    start = focused()
    other = if start == 1, do: 2, else: 1
    {b1, b2} = {written(start), written(other)}

    :ok = Store.run({Actions, :cycle, [:next]}, @size)

    assert focused() == other
    assert written(start) == b1 <> "\e[O"
    assert written(other) == b2 <> "\e[I"
  end

  test "nothing is written with the mode off, or when the focus did not change" do
    start = focused()
    other = if start == 1, do: 2, else: 1
    {b1, b2} = {written(start), written(other)}
    :ok = Store.run({Actions, :cycle, [:next]}, @size)
    assert {written(start), written(other)} == {b1, b2}

    for id <- [1, 2], do: :ok = Fake.Vt.set_mode(res(id).vt, :focus_events, true)
    :ok = Store.event({:resize, %{cols: 100, rows: 30, cell_px: nil}}, %{cols: 100, rows: 30})
    assert {written(start), written(other)} == {b1, b2}
  end
end
