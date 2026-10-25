defmodule HerdrServer.View.Status do
  @moduledoc """
  The status row region (pure): `:mode` (the client's own input mode, `props: %{mode}`,
  or an open copy-mode search prompt),
  herdr's mode-bar hints in prefix and resize modes (`:keycap` `{:key, n}` with
  `props: %{key, mods}` and its label as text, then a `:muted` `:text` `{:hint_text, n}`),
  the runtime status `:reload`, `:tests`, `:handoff` from `client.runtime`
  (`RuntimeStatus.nodes/2`, those that fit), `:notice` when the client has one, `:title`
  (the focused pane's) and `:hint` (the prefix key, `props: %{key, mods}`; empty props when
  hidden). Tabs are their own region (`View.Tabs`).
  """

  alias HerdrScene.Scene.Node
  alias HerdrServer.Client.CopyMode
  alias HerdrServer.RuntimeStatus

  @spec node(map, HerdrServer.Client.State.t(), HerdrScene.Scene.rect()) :: Node.t()
  def node(app, client, rect) do
    mode = mode(client.mode, client.copy)
    hint = hint(client.mode, app.ui)
    left = [mode | fit(hints(client.mode, app.ui), rect.w - width([mode, hint]))]
    free = rect.w - width(left) - width([hint])
    runtime = RuntimeStatus.nodes(client.runtime, free)
    left = left ++ runtime

    %Node{
      role: :status,
      id: :status,
      rect: rect,
      children: left ++ notice(client.notice, free - width(runtime)) ++ [title(app), hint]
    }
  end

  # an open copy-mode search prompt shows as the label (`/query`, `?query`)
  defp mode(:copy, %CopyMode{} = copy) when copy.prompt != nil,
    do: %{text(:mode, CopyMode.label(copy), :accent) | props: %{mode: :copy}}

  defp mode(m, _copy) do
    {label, token} =
      case m do
        :terminal -> {"TERMINAL", :default}
        :prefix -> {"PREFIX", :accent}
        :resize -> {"RESIZE", :warning}
        :copy -> {"COPY", :accent}
      end

    %{text(:mode, label, token) | props: %{mode: m}}
  end

  defp hints(:prefix, ui) do
    prefix = List.first(ui.keybinds.prefix)

    pairs(
      [{{:escape, []}, "cancel"}] ++
        if(prefix, do: [{prefix, "send prefix"}], else: []) ++ [{{"?", []}, "keybinds"}]
    )
  end

  defp hints(:resize, _ui) do
    keys = [{"h", nil}, {"l", "width"}, {"j", nil}, {"k", "height"}, {:escape, "done"}]
    pairs(for {k, label} <- keys, do: {{k, []}, label})
  end

  defp hints(_mode, _ui), do: []

  # whole hints (a keycap with its label) in order while they fit `budget` cells, counted
  # as the client draws them (`width/1`: text plus one gap each); the client only clips
  # by cell, so this keeps a hint from being cut mid-label
  defp fit(groups, budget) do
    groups
    |> Enum.reduce_while({[], budget}, fn g, {acc, left} ->
      w = width(g)
      if w <= left, do: {:cont, {[g | acc], left - w}}, else: {:halt, {acc, 0}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> List.flatten()
  end

  # one group per hint: a keycap, then its label unless nil (keys sharing one label)
  defp pairs(hints) do
    hints
    |> Enum.with_index()
    |> Enum.map(fn {{{key, mods}, label}, i} ->
      cap = %Node{
        role: :keycap,
        id: {:key, i},
        text: key_label(key, mods),
        props: %{key: key, mods: mods}
      }

      if label, do: [cap, text({:hint_text, i}, label, :muted)], else: [cap]
    end)
  end

  defp key_label(:escape, []), do: "esc"
  defp key_label(key, mods), do: Enum.map_join(mods ++ [key], "+", &to_string/1)

  defp title(app) do
    meta = Map.get(app.session.panes, app.focus.pane)
    text(:title, (meta && meta.title) || "", :muted)
  end

  defp hint(mode, ui) do
    case ui.keybinds.prefix do
      [{key, mods} | _] when mode in [:terminal, :prefix] and ui.status.show_hints ->
        %{text(:hint, key_label(key, mods), :muted) | props: %{key: key, mods: mods}}

      _ ->
        text(:hint, "", :muted)
    end
  end

  # before the title so a long title cannot hide it; clipped to the cells left after the
  # mode, runtime status and hint, dropped below 4 cells
  defp notice(nil, _free), do: []
  defp notice(_n, free) when free < 4, do: []

  defp notice(%{level: level, text: text}, free) do
    token = Map.get(%{error: :error, warning: :warning}, level, :muted)
    [text(:notice, String.slice(text, 0, free), token)]
  end

  @doc "Cells a status renderer gives these nodes: their text, one gap after each."
  @spec width([Node.t()]) :: integer
  def width(nodes) do
    nodes
    |> Enum.map(fn
      %Node{text: t} when t in [nil, ""] -> 0
      %Node{text: t} -> String.length(t) + 1
    end)
    |> Enum.sum()
  end

  defp text(id, text, token), do: %Node{role: :text, id: id, text: text, token: token}
end
