defmodule HerdrServer.Kernel.Pty do
  @moduledoc """
  PTY kernel (design.md, Native.Pty). Subscribers receive `{:damage, id, gen}`,
  `{:exit, id, status}`, `{:title, id, binary}`, `{:bell, id}`,
  `{:osc, id, code, payload}` and `{:pwd, id, binary}`; `id` is the pane id.
  Subscribing forces full damage on the vt.
  """

  @type pty :: term

  @callback spawn(
              vt :: term,
              cmd :: binary,
              args :: [binary],
              env :: [{binary, binary}],
              cwd :: binary,
              pos_integer,
              pos_integer
            ) :: {:ok, pty, integer}
  @callback write(pty, binary) :: :ok | {:error, :backpressure}
  @callback resize(pty, pos_integer, pos_integer, {pos_integer, pos_integer} | nil) :: :ok
  @callback kill(pty, atom) :: :ok
  @callback subscribe(pty, pid) :: :ok
  @callback set_hidden(pty, boolean) :: :ok
end
