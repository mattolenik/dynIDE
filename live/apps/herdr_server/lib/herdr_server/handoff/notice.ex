defmodule HerdrServer.Handoff.Notice do
  @moduledoc """
  Handoff progress for subscribers (`Client.Session`, the local client):

      {:handoff, %{phase: :begin | :aborted | :released | :adopted, gen: integer, panes: [id]}}

  `:begin` (old VM, before freezing): stop writing to panes. `:aborted`: the restart
  failed and panes run again. `:released`: this VM is about to exit. `:adopted` (new VM):
  the panes are back.
  """

  @type event ::
          {:handoff,
           %{phase: :begin | :aborted | :released | :adopted, gen: integer, panes: [pos_integer]}}

  def child_spec(_opts), do: Registry.child_spec(keys: :duplicate, name: __MODULE__)

  @spec subscribe() :: :ok
  def subscribe do
    {:ok, _} = Registry.register(__MODULE__, :handoff, nil)
    :ok
  end

  @spec broadcast(event) :: :ok
  def broadcast(event) do
    Registry.dispatch(__MODULE__, :handoff, fn subs ->
      for {pid, _} <- subs, do: send(pid, event)
    end)
  end
end
