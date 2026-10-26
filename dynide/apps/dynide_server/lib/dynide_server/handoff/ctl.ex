defmodule DynideServer.Handoff.Ctl do
  @moduledoc """
  Answers broker ctl requests (`dynide` CLI, benches) against the kernel Keeper.
  Payloads per `docs/herdr-live/plans/m5.md` "Wire protocol"; anything else is
  `{:error, :unknown_request}`.
  """

  alias DynideServer.Native.{Keeper, Pty, Vt}

  @spec handle(term) :: term
  def handle(:ping), do: :pong

  def handle({:open, %{cmd: _, args: _, cols: _, rows: _} = req}) do
    req
    |> Map.take([:cmd, :args, :cols, :rows, :env, :cwd, :max_scrollback])
    |> Enum.into(%{env: [], cwd: nil, max_scrollback: 10_000_000, subscriber: nil})
    |> Keeper.open()
  end

  def handle({:write, id, data}) when is_binary(data) do
    case Keeper.lookup(id) do
      {:ok, %{pty: pty}} -> Pty.write(pty, data)
      :error -> {:error, :unknown_pane}
    end
  end

  def handle({:text, id}) do
    with {:ok, %{vt: vt}} <- Keeper.lookup(id), do: {:ok, Vt.read_text(vt, :screen)}
  end

  # kitty placements (benches: images across a handoff)
  def handle({:graphics, id}) do
    with {:ok, %{vt: vt}} <- Keeper.lookup(id), do: {:ok, Vt.graphics_placements(vt)}
  end

  def handle(:panes) do
    for id <- Keeper.ids(), {:ok, %{os_pid: p}} <- [Keeper.lookup(id)], do: {id, p}
  end

  def handle({:close, id}), do: Keeper.close(id)
  def handle(_), do: {:error, :unknown_request}
end
