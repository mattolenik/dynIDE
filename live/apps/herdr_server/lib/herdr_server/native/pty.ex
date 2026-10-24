defmodule HerdrServer.Native.Pty do
  @moduledoc """
  A child process on a PTY, feeding a `HerdrServer.Native.Vt` from kernel
  threads. Subscribers receive (`id` is the one given to `spawn/8`):

      {:damage, id, gen}
      {:exit, id, status}   status :: non_neg_integer | {:signal, n} | {:panic, binary} | :unknown
      {:osc, id, code, payload}
      {:dcs, id, payload}   payload :: binary | {:truncated, binary}
      {:bell, id}
      {:title, id, binary}
      {:pwd, id, binary}
  """
  alias HerdrServer.Native
  alias HerdrServer.Native.Vt

  @opaque pty :: reference
  @type signal :: :hup | :term | :kill | :int | pos_integer

  @doc "Spawns `cmd` with `args` on a new PTY of `cols` x `rows`; `env` entries override the inherited environment."
  @spec spawn(
          Vt.vt(),
          non_neg_integer,
          binary,
          [binary],
          [{binary, binary}],
          binary | nil,
          pos_integer,
          pos_integer
        ) :: {:ok, pty, pos_integer} | {:error, term}
  def spawn(vt, id, cmd, args, env, cwd, cols, rows),
    do: Native.pty_spawn(vt, id, cmd, args, env, cwd, cols, rows)

  @doc "Queues `data` for the child. Never blocks: a full queue is `{:error, :backpressure}`."
  @spec write(pty, iodata) :: :ok | {:error, :backpressure | :closed}
  def write(pty, data), do: Native.pty_write(pty, data)

  @doc "Sets the PTY window size; `cell_px` is the pixel size of one cell, as in `Vt.resize/4`."
  @spec resize(pty, pos_integer, pos_integer, Vt.cell_px()) :: :ok
  def resize(pty, cols, rows, cell_px), do: Native.pty_resize(pty, cols, rows, cell_px)

  @doc "Sends a signal to the child. Unknown signal names raise `ArgumentError`."
  @spec kill(pty, signal) :: :ok
  def kill(pty, signal), do: Native.pty_kill(pty, signal)

  @doc """
  Monitors `pid` and sends it events. Always triggers a full-damage resend; an
  exit that already happened follows that damage.
  """
  @spec subscribe(pty, pid) :: :ok
  def subscribe(pty, pid), do: Native.pty_subscribe(pty, pid)

  @doc "Hidden panes keep parsing but emit no damage; unhiding sends a full damage."
  @spec set_hidden(pty, boolean) :: :ok
  def set_hidden(pty, hidden), do: Native.pty_set_hidden(pty, hidden)
end
