defmodule HerdrServer.Client.Foreground do
  @moduledoc """
  The foreground client (ruling 4): the session that most recently handled a slow-path
  input or attached. Pane bells, child OSC 52 and host colours go to it alone. Kept in
  `Pane.Facts` under `:foreground`; any process reads and writes it without a call.
  """

  alias HerdrServer.Pane.Facts

  @doc "Makes `pid` the foreground client (writes only when it changes)."
  @spec mark(pid) :: :ok
  def mark(pid) do
    if Facts.get(:foreground) == pid, do: :ok, else: Facts.put(:foreground, pid)
  end

  @doc "The foreground client session, or nil."
  @spec current() :: pid | nil
  def current, do: Facts.get(:foreground)

  @doc "Sends `msg` to the foreground client if it is alive, else drops it."
  @spec send(term) :: :ok
  def send(msg) do
    case Facts.get(:foreground) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: Kernel.send(pid, msg)
      _none -> nil
    end

    :ok
  end
end
