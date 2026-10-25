defmodule HerdrServer.Persist.RestorePlan do
  @moduledoc """
  Pure: the pane spawns that bring a restored app (`Persist.Schema.restore/1`) back to life.

  One `{:spawn, id, %{cols, rows}, %{cwd, replay}}` Store effect per pane of every tab,
  sized to that tab's content rect (`Layout.size/4`),
  so inactive tabs come back at the size they will have when shown. `cwd` is the
  recorded cwd when it still exists, else its nearest existing ancestor, else nil (the
  Store then uses its own cwd). `replay` is the pane's saved scrollback followed by an
  attribute reset and a new line, so the shell's prompt starts clean below it.

  `resumes/2`: with `session.resume_agents_on_restore`, one delayed write per pane whose
  `agent_session` plans a resume (`AgentResume.plan/1`), in layout order: `{ms,
  {:paste_raw, id, AgentResume.shell(argv) <> "\\r"}}` at `n * startup_per_agent_delay_ms`
  for the n-th (from 1). The Store sends each to itself with `Process.send_after/3`
  and writes it raw to the pane's write queue, the path `pane.send_text` uses.
  """

  alias HerdrServer.{AgentResume, Config, Layout}

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

  @type resume :: {non_neg_integer, {:paste_raw, pos_integer, binary}}

  @doc """
  The resume writes for `app`. `[session]` is file-only: `cfg` (the config file as
  `Config.load/1` reads it) over the default `App.Ui` session, never the persisted one, so
  a missing key, a failed load or nil means off. The delay is clamped to 0..60000.
  """
  @spec resumes(map, Config.t() | nil) :: [resume]
  def resumes(app, cfg) do
    ui = %{app.ui | session: struct(HerdrServer.App.Ui).session}
    ui = if cfg, do: elem(Config.apply(cfg, ui.keybinds, ui), 1), else: ui
    %{resume_agents_on_restore: on?, startup_per_agent_delay_ms: delay} = ui.session
    delay = if is_integer(delay), do: min(max(delay, 0), 60_000), else: 500

    if on? == true do
      for(
        ws <- app.session.workspaces,
        tab <- ws.tabs,
        id <- Layout.pane_ids(tab.layout),
        {:ok, argv} <- [AgentResume.plan(Map.get(app.session.panes[id] || %{}, :agent_session))],
        do: {:paste_raw, id, AgentResume.shell(argv) <> "\r"}
      )
      |> Enum.with_index(1)
      |> Enum.map(fn {w, n} -> {n * delay, w} end)
    else
      []
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
