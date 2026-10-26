defmodule DynideServer.Pane.Colors do
  @moduledoc """
  Host colours on pane vts (ruling 5: ghostty's own defaults, so it answers OSC
  10/11/12/4 and `CSI ? 996 n` itself). `apply/3` sets one vt from stored host colours
  (`Pane.Facts.host_colors/0`, `%{colors, scheme}`, either key optional);
  `apply_all/1` stores the foreground client's caps and applies them to every live
  pane, and on a dark/light change writes the `CSI ? 997 ; 1|2 n` report to panes whose
  child enabled mode 2031 (ghostty never sends it unsolicited). A raising kernel call
  is logged and skipped for that pane.
  """

  require Logger

  alias DynideServer.Kernel
  alias DynideServer.Pane.{Facts, Rows, Server}

  @doc "Applies `hc` to `vt`; returns the colours set, or nil (none stored, or refused)."
  @spec apply(pos_integer, term, map) :: map | nil
  def apply(id, vt, hc) do
    if Map.has_key?(hc, :scheme),
      do: kernel(id, :set_color_scheme, fn -> Kernel.vt().set_color_scheme(vt, hc.scheme) end)

    colors = hc[:colors]

    if colors != nil and
         kernel(id, :set_colors, fn -> Kernel.vt().set_colors(vt, colors) end) == :ok,
       do: colors
  end

  @doc "Stores `caps` as the host colours and applies them to every pane; `{:error, :invalid}` stores nothing."
  @spec apply_all(map) :: :ok | {:error, :invalid}
  def apply_all(caps) do
    old = (Facts.host_colors() || %{})[:scheme]

    with :ok <- Facts.put_host_colors(caps) do
      hc = Facts.host_colors()
      new = caps[:scheme]
      report = if new in [:dark, :light] and new != old, do: report(new)

      for {id, kid} <- Rows.kernel_ids(),
          {:ok, %{vt: vt}} <- [Kernel.keeper().lookup(kid)],
          do: apply_pane(id, vt, hc, report)

      :ok
    end
  end

  defp apply_pane(id, vt, hc, report) do
    __MODULE__.apply(id, vt, hc)
    if report && reports?(id, vt), do: Server.write(id, report)
  end

  defp report(:dark), do: "\e[?997;1n"
  defp report(:light), do: "\e[?997;2n"

  defp reports?(id, vt) do
    kernel(id, :mode, fn -> Kernel.vt().mode(vt, :color_scheme_report) end) in [
      true,
      {:stale, true}
    ]
  end

  defp kernel(id, op, fun) do
    case fun.() do
      :ok -> :ok
      other when op == :mode -> other
      other -> failed(id, op, other)
    end
  rescue
    e in [ArgumentError, ErlangError] -> failed(id, op, {:raised, Exception.message(e)})
  end

  defp failed(id, op, why) do
    Logger.warning("pane #{id}: #{op} failed: #{inspect(why)}")
    :error
  end
end
