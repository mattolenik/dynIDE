defmodule HerdrServer.Kernel.Pty do
  @moduledoc """
  PTY kernel: the API of `HerdrServer.Native.Pty` (M1). Subscribers receive (`id` is the
  kernel id given to `spawn/8`, allocated by the keeper; `Pane.Server` translates it to
  the pane id):

      {:damage, id, gen}
      {:exit, id, non_neg_integer | {:signal, n} | {:panic, binary} | :unknown}
      {:osc, id, code, binary | {:truncated, binary}}
      {:dcs, id, binary | {:truncated, binary}}
      {:bell, id}
      {:title, id, binary}
      {:pwd, id, binary}

  Every `subscribe/2` resets the vt's `dirty_rows` cursor and resends full damage.
  """

  @type pty :: term
  @type signal :: :hup | :term | :kill | :int | pos_integer

  @callback spawn(
              vt :: term,
              id :: non_neg_integer,
              cmd :: binary,
              args :: [binary],
              env :: [{binary, binary}],
              cwd :: binary | nil,
              pos_integer,
              pos_integer
            ) :: {:ok, pty, pos_integer} | {:error, term}
  @callback write(pty, iodata) :: :ok | {:error, :backpressure | :closed | :too_large}
  @callback resize(pty, pos_integer, pos_integer, {pos_integer, pos_integer} | nil) :: :ok
  @callback kill(pty, signal) :: :ok
  @callback subscribe(pty, pid) :: :ok
  @callback set_hidden(pty, boolean) :: :ok
  @doc "The child's working directory (absolute), or nil when unknown."
  @callback cwd(pty) :: binary | nil
  @callback info(pty) :: %{optional(atom) => term}

  @type job :: %{
          pgid: pos_integer,
          shell: boolean,
          processes: [%{pid: pos_integer, name: binary, argv: [binary]}]
        }

  @doc "Output chunks read so far, counted while hidden too."
  @callback activity(pty) :: non_neg_integer
  @doc "The terminal's foreground process group, or nil when closed or unreadable."
  @callback foreground_pgid(pty) :: pos_integer | nil
  @doc "The foreground job; `shell` when it is the child's own process group."
  @callback foreground_job(pty) :: job | nil
end
