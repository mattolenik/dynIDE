defmodule HerdrServer.Kernel.Keeper do
  @moduledoc """
  Owns the vt/pty resources per pane. Callers never hold a resource past a
  `lookup/1`. Not in design.md; proposed to M1.

  `lookup/1` is on the keystroke path (`Pane.Input` runs it for every fast-path key, in
  the client's process): it must be callable from any process and must not serialize
  through one GenServer (e.g. a `read_concurrency` ETS table written by the keeper).
  `Kernel.Fake.Keeper` answers with a `GenServer.call`, which is acceptable for tests only.
  """

  @type resources :: %{vt: term, pty: term, os_pid: integer}
  @type opts :: %{
          cmd: binary,
          args: [binary],
          env: [{binary, binary}],
          cwd: binary,
          cols: pos_integer,
          rows: pos_integer
        }

  @callback child_spec(term) :: Supervisor.child_spec()
  @callback open(pane_id :: term, opts) :: {:ok, resources} | {:error, term}
  @callback lookup(pane_id :: term) :: {:ok, resources} | :error
  @callback close(pane_id :: term) :: :ok
  @callback pane_ids() :: [term]
end
