defmodule HerdrServer.View.WindowTitle do
  @moduledoc """
  Pure: the outer terminal's window title for the scene root's `:window_title` prop.

  Tokens of `ui.window_title`: `{hostname}`, `{workspace}`, `{tab}`, `{pane}` (the
  focused pane's name), `{terminal_title}` (its terminal-set title). C0/C1 controls are
  stripped and the result is at most 200 characters; an empty result is nil.
  """

  @max 200

  @spec render(binary | nil, map, binary | nil, binary | nil) :: binary | nil
  def render(template, app, pane_title, hostname \\ nil)

  def render(template, app, pane_title, hostname) when is_binary(template) do
    ws = Enum.find(app.session.workspaces, &(&1.id == app.session.active_workspace))
    tab = ws && Enum.find(ws.tabs, &(&1.id == ws.active_tab))
    pane = Map.get(app.session.panes, app.focus.pane, %{})

    values = %{
      "hostname" => hostname,
      "workspace" => ws && ws.name,
      "tab" => tab && tab.name,
      "pane" => Map.get(pane, :name),
      "terminal_title" => pane_title
    }

    template
    |> then(&Regex.replace(~r/\{(\w+)\}/, &1, fn all, k -> Map.get(values, k, all) || "" end))
    |> clean()
  end

  def render(_template, _app, _pane_title, _hostname), do: nil

  @doc "Strips controls, caps the length; an empty result is nil."
  @spec clean(binary) :: binary | nil
  def clean(text) do
    case text |> String.replace(~r/[\x00-\x1f\x7f\x{80}-\x{9f}]/u, "") |> String.slice(0, @max) do
      "" -> nil
      t -> t
    end
  end
end
