defmodule HerdrServer.Pane.Input do
  @moduledoc """
  Writes input to a pane: encode with the pane's vt (live modes), write to its pty.
  `key/2` is the fast-path target published by `App.Store` (contract decision 6):
  clients call `apply(Pane.Input, :key, [event, pane_id])`. Unknown panes are a no-op.
  """

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
         bytes when is_binary(bytes) and bytes != "" <- encode.(vt) do
      # ponytail: {:error, :backpressure} drops the input; queue in Pane.Server if it shows up
      _ = Kernel.pty().write(pty, bytes)
    end

    :ok
  end

  defp bracket(vt, bin) do
    if on?(Kernel.vt().mode(vt, 2004)), do: "\e[200~" <> bin <> "\e[201~", else: bin
  end

  defp on?({:stale, b}), do: b
  defp on?(b), do: b
end
