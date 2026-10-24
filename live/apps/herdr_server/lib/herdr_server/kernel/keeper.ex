defmodule HerdrServer.Kernel.Keeper do
  @moduledoc """
  Owns the vt/pty resources per pane. Callers never hold a resource past a
  `lookup/1`. Not in design.md; proposed to M1.
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
