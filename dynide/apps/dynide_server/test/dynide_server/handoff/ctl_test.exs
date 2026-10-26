defmodule DynideServer.Handoff.CtlTest do
  use ExUnit.Case, async: false

  alias DynideServer.Handoff.Ctl

  defp wait_text(id, s, deadline \\ System.monotonic_time(:millisecond) + 3000) do
    {:ok, text} = Ctl.handle({:text, id})

    cond do
      text =~ s -> true
      System.monotonic_time(:millisecond) > deadline -> false
      true -> Process.sleep(20) && wait_text(id, s, deadline)
    end
  end

  test "ping" do
    assert Ctl.handle(:ping) == :pong
  end

  test "open, write, text, panes, close" do
    open = %{cmd: "/bin/sh", args: [], cols: 80, rows: 24, env: [{"PS1", "$ "}, {"ENV", ""}]}
    assert {:ok, id} = Ctl.handle({:open, open})
    assert Ctl.handle({:write, id, "echo ctl-$((4+2))\n"}) == :ok
    assert wait_text(id, "ctl-6")
    assert [{^id, os_pid}] = Enum.filter(Ctl.handle(:panes), &(elem(&1, 0) == id))
    assert is_integer(os_pid)
    assert Ctl.handle({:close, id}) == :ok
    assert Ctl.handle({:text, id}) == :error
    assert {:error, _} = Ctl.handle({:write, id, "x"})
    assert {:error, _} = Ctl.handle({:open, %{cmd: "/bin/sh"}})
    assert {:error, _} = Ctl.handle(:nonsense)
  end
end
