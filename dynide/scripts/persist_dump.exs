# Prints a dynIDE session file (M8, `<state dir>/session.<name>.etf`) as canonical
# k=v lines, so two snapshots compare as text (tty_harness.py persist):
#   saved_at=<ms>    (first line; drop it to compare layouts)
#   session active_workspace=<id> next_id=<n> size=<cols>x<rows> focus=<pane>
#   workspace=<id> name=<name> active_tab=<id>
#   tab=<ws>/<id> name=<name> root=<tree> focus=<pane> prev_focus=<pane>
#   pane=<id> cwd=<cwd>
# Trees: p<id> for a pane, h(<ratio>,a,b) / v(<ratio>,a,b) for a split. Names and cwds
# are inspect/1-quoted. Left out: area, ui, titles, commands, hidden.
# Usage: elixir persist_dump.exs FILE    (exit 2 on an unreadable or malformed file)
defmodule PersistDump do
  def main([path]) do
    with {:ok, bin} <- File.read(path),
         {:ok, %{format: :dynide_session, v: v, snapshot: s} = env} when is_integer(v) <-
           decode(bin) do
      IO.puts("saved_at=#{env.saved_at}")
      s |> lines() |> Enum.each(&IO.puts/1)
    else
      other -> bad(path, other)
    end
  rescue
    e -> bad(path, Exception.message(e))
  end

  def main(_), do: bad("", :usage)

  defp decode(bin) do
    {:ok, :erlang.binary_to_term(bin)}
  rescue
    ArgumentError -> {:error, :not_etf}
  end

  defp lines(%{session: se, focus: focus, panes: panes}) do
    size = Map.get(se, :size, %{})

    head =
      "session active_workspace=#{se.active_workspace} next_id=#{se.next_id} " <>
        "size=#{size[:cols]}x#{size[:rows]} focus=#{focus.pane}"

    wss =
      Enum.flat_map(se.workspaces, fn ws ->
        [
          "workspace=#{ws.id} name=#{inspect(ws.name)} active_tab=#{ws.active_tab}"
          | Enum.map(ws.tabs, fn t ->
              l = t.layout

              "tab=#{ws.id}/#{t.id} name=#{inspect(t.name)} root=#{tree(l.root)} " <>
                "focus=#{l.focus} prev_focus=#{l.prev_focus}"
            end)
        ]
      end)

    ps = panes |> Enum.sort() |> Enum.map(fn {id, p} -> "pane=#{id} cwd=#{inspect(p.cwd)}" end)
    [head | wss] ++ ps
  end

  defp tree({:pane, id}), do: "p#{id}"
  defp tree({:split, :horizontal, r, a, b}), do: "h(#{r},#{tree(a)},#{tree(b)})"
  defp tree({:split, :vertical, r, a, b}), do: "v(#{r},#{tree(a)},#{tree(b)})"
  defp tree(nil), do: "none"

  defp bad(path, why) do
    IO.puts(:stderr, "persist_dump: #{path}: #{inspect(why)}")
    System.halt(2)
  end
end

PersistDump.main(System.argv())
