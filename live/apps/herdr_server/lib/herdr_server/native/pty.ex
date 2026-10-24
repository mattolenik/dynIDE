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

  Per 4 ms damage window, `:title` and `:pwd` carry only the last value (flushed
  with the damage, or before the exit), `:osc` plus `:dcs` are capped at 64 (the
  excess is dropped), and `:bell` is at most one per read chunk. Hidden panes
  still send these events.
  """
  @behaviour HerdrServer.Kernel.Pty

  alias HerdrServer.Native
  alias HerdrServer.Native.Vt

  @opaque pty :: reference
  @type signal :: :hup | :term | :kill | :int | pos_integer
  @typedoc """
  A posix atom when the OS reported an errno (an exec failure), `{:os, errno}` for
  other errnos, `{:spawn, message}` when there is none (portable-pty's own checks,
  e.g. a missing executable is
  `{:spawn, "Unable to spawn /x because it doesn't exist on the filesystem (ENOENT: ...)"}`).
  """
  @type spawn_error ::
          :enoent | :eacces | :enotdir | :enoexec | :e2big | {:os, pos_integer} | {:spawn, binary}

  @doc """
  Spawns `cmd` with `args` on a new PTY of `cols` x `rows`; `env` entries override the
  inherited environment. Raises `ArgumentError` for sizes outside 1..65535.
  """
  @spec spawn(
          Vt.vt(),
          non_neg_integer,
          binary,
          [binary],
          [{binary, binary}],
          binary | nil,
          pos_integer,
          pos_integer
        ) :: {:ok, pty, pos_integer} | {:error, spawn_error}
  def spawn(vt, id, cmd, args, env, cwd, cols, rows) do
    Vt.check_size!(cols, rows)
    Native.pty_spawn(vt, id, cmd, args, env, cwd, cols, rows)
  end

  @doc """
  Queues `data` for the child. Never blocks. The queue holds 1 MiB: a write is
  accepted whenever the queue is empty, else a full queue is `{:error, :backpressure}`.
  A single write over 1 MiB is `{:error, :too_large}` (chunk large pastes).
  """
  @spec write(pty, iodata) :: :ok | {:error, :backpressure | :closed | :too_large}
  def write(pty, data), do: Native.pty_write(pty, data)

  @doc """
  Sets the PTY window size; `cell_px` is the pixel size of one cell, as in `Vt.resize/4`.
  Raises `ArgumentError` for sizes outside 1..65535.
  """
  @spec resize(pty, pos_integer, pos_integer, Vt.cell_px()) :: :ok
  def resize(pty, cols, rows, cell_px) do
    Vt.check_size!(cols, rows)
    Native.pty_resize(pty, cols, rows, cell_px)
  end

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
