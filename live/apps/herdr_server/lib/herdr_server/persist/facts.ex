defmodule HerdrServer.Persist.Facts do
  @moduledoc """
  Per-pane runtime facts for a snapshot (the `Persist.Schema.facts` shape): `cwd` from
  the pty (process cwd, OSC 7 fallback), `command` from the keeper row, `hidden` from
  the mirror. A fact the kernel no longer reports (pane unmapped, process exited) keeps
  its value from `prev`.
  """

  alias HerdrServer.{Kernel, Mirror}
  alias HerdrServer.Pane.Rows
  alias HerdrServer.Persist.Schema

  @doc "Facts for every pane in `app.session.panes`, falling back to `prev` per field."
  @spec collect(map, Schema.facts()) :: Schema.facts()
  def collect(app, prev \\ %{}) do
    Map.new(app.session.panes, fn {id, _meta} -> {id, fact(id, Map.get(prev, id, %{}))} end)
  end

  defp fact(id, prev) do
    row = row(id)

    %{
      cwd: (row && Kernel.pty().cwd(row.pty)) || Map.get(prev, :cwd),
      command: (row && Map.get(row, :cmd)) || Map.get(prev, :command),
      hidden:
        case Mirror.pane(id) do
          %{hidden: h} -> h == true
          _ -> Map.get(prev, :hidden, false) == true
        end
    }
  end

  @doc "The last `rows` lines of pane `id`'s history as ANSI, `:alt_screen`, or nil."
  @spec tail(pos_integer, non_neg_integer) :: binary | :alt_screen | nil
  def tail(_id, 0), do: nil

  def tail(id, rows) do
    case row(id) do
      nil -> nil
      r -> Kernel.vt().tail_ansi(r.vt, rows)
    end
  end

  @doc "Pane `id`'s content generation, or nil."
  @spec gen(pos_integer) :: non_neg_integer | nil
  defdelegate gen(id), to: Rows

  defp row(id) do
    with kid when kid != nil <- Rows.kernel_id(id),
         {:ok, r} <- Kernel.keeper().lookup(kid) do
      r
    else
      _ -> nil
    end
  end
end
