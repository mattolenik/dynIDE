defmodule HerdrServer.Persist.RestorePlan do
  @moduledoc """
  Pure: the pane spawns that bring a restored app (`Persist.Schema.restore/1`) back to life.

  One `{:spawn, id, %{cols, rows}, %{cwd, replay}}` Store effect per pane of every tab,
  sized to that tab's content rect (`Layout.size/4`),
  so inactive tabs come back at the size they will have when shown. `cwd` is the
  recorded cwd when it still exists, else its nearest existing ancestor, else nil (the
  Store then uses its own cwd). `replay` is the pane's saved scrollback followed by an
  attribute reset and a new line, so the shell's prompt starts clean below it.
  """

  alias HerdrServer.Layout

  @reset "\e[0m\r\n"

  @type spawn ::
          {:spawn, pos_integer, %{cols: pos_integer, rows: pos_integer},
           %{cwd: binary | nil, replay: binary | nil}}

  @doc "The spawns for `app`; `exists?` says whether a directory exists (never stored)."
  @spec spawns(map, %{pos_integer => map}, %{pos_integer => binary}, (binary -> boolean)) ::
          [spawn]
  def spawns(app, facts, scrollback, exists?) do
    s = app.session

    for ws <- s.workspaces,
        tab <- ws.tabs,
        id <- Layout.pane_ids(tab.layout) do
      size = Layout.size(tab.layout, s.area, Layout.opts(tab, app.ui), id)
      cwd = facts |> Map.get(id, %{}) |> Map.get(:cwd)
      opts = %{cwd: existing(cwd, exists?), replay: replay(Map.get(scrollback, id))}
      {:spawn, id, size, opts}
    end
  end

  defp existing(nil, _exists?), do: nil

  defp existing(dir, exists?) do
    cond do
      exists?.(dir) -> dir
      Path.dirname(dir) == dir -> nil
      true -> existing(Path.dirname(dir), exists?)
    end
  end

  defp replay(bytes) when is_binary(bytes) and bytes != "", do: bytes <> @reset
  defp replay(_none), do: nil
end
