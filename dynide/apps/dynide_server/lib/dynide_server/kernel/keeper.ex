defmodule DynideServer.Kernel.Keeper do
  @moduledoc """
  Owns the vt/pty resources per kernel id: the API of `DynideServer.Native.Keeper` (M1).
  `open/1` allocates the id. Pane ids are allocated by `App.Actions`; the
  pane id -> kernel id map lives in `Pane.Rows`.

  `lookup/1` is on the keystroke path (`Pane.Input` runs it in the client's process):
  `Native.Keeper` reads a `read_concurrency` ETS table. `Kernel.Fake.Keeper` answers with
  a `GenServer.call`, acceptable for tests only.
  """

  @type id :: pos_integer
  @typedoc "`cmd` is `[spec.cmd | spec.args]`; nil for a pane adopted from a blob without it."
  @type resources :: %{vt: term, pty: term, os_pid: integer, cmd: [binary] | nil}
  @type spec :: %{
          optional(:replay) => binary | nil,
          cmd: binary,
          args: [binary],
          env: [{binary, binary | nil}],
          cwd: binary | nil,
          cols: pos_integer,
          rows: pos_integer,
          max_scrollback: non_neg_integer,
          subscriber: pid | nil
        }

  @callback child_spec(term) :: Supervisor.child_spec()
  @callback open(spec) :: {:ok, id} | {:error, term}
  @callback lookup(id) :: {:ok, resources} | :error
  @callback close(id) :: :ok
  @callback ids() :: [id]
end
