defmodule HerdrServer.Pane.Input do
  @moduledoc """
  Writes input to a pane: encode with the pane's vt (live modes), write to its pty.
  `key/2` is the fast-path target published by `App.Store` (contract decision 6):
  clients call `apply(Pane.Input, :key, [event, pane_id])`. Unknown panes are a no-op.
  """

  require Logger

  alias HerdrServer.Kernel

  @spec key(tuple, pos_integer) :: :ok
  def key(event, id), do: write(id, &Kernel.vt().encode_key(&1, event))

  @spec mouse(tuple, pos_integer) :: :ok
  def mouse(event, id), do: write(id, &Kernel.vt().encode_mouse(&1, event))

  @spec paste(binary, pos_integer) :: :ok
  def paste(bin, id), do: write(id, &bracket(&1, bin))

  @spec focus(boolean, pos_integer) :: :ok
  def focus(focused?, id), do: write(id, &Kernel.vt().encode_focus(&1, focused?))

  defp write(id, encode) do
    with {:ok, %{vt: vt, pty: pty}} <- Kernel.keeper().lookup(id),
         bytes when is_binary(bytes) and bytes != "" <- encode.(vt),
         # ponytail: {:error, :backpressure} drops the input; queue in Pane.Server if it shows up
         {:error, reason} <- Kernel.pty().write(pty, bytes) do
      warn(id, reason)
    end

    :ok
  end

  @warn_every_ms 1000

  # at most one warning per pane per second per calling process (the caller's dictionary
  # keeps the time: writers are client processes, there is no process of our own here)
  defp warn(id, reason) do
    now = System.monotonic_time(:millisecond)
    key = {__MODULE__, :warned, id}

    if now - Process.get(key, now - @warn_every_ms) >= @warn_every_ms do
      Process.put(key, now)
      Logger.warning("pane #{id}: input dropped (#{inspect(reason)})")
    end
  end

  defp bracket(vt, bin) do
    if on?(Kernel.vt().mode(vt, 2004)), do: "\e[200~" <> bin <> "\e[201~", else: bin
  end

  defp on?({:stale, b}), do: b
  defp on?(b), do: b
end
