defmodule HerdrServer.View.Overlays do
  @moduledoc """
  Pure: semantic `Scene.Overlay`s of one pane from the client's own state.

  Order: `:scrollbar` (pane scrolled back, from `client.facts`), `:selection`
  (`Client.Selection.overlay/4` through the facts' scroll offset), `:link_hover`
  (`pointer.hover` on this pane). Copy mode overlays (search matches, copy cursor, from
  `client.copy`) go in `copy/3`, the extension point for the copy-mode task.
  No state for the pane means `[]` without any per-row work.
  """

  alias HerdrScene.Scene.Overlay
  alias HerdrServer.Client.Selection

  @spec pane(term, %{w: integer, h: integer}, map) :: [Overlay.t()]
  def pane(id, rect, client) do
    facts = Map.get(client.facts, id)

    scrollbar(facts) ++
      selection(client.pointer, id, rect, facts) ++
      hover(client.pointer, id) ++ copy(client, id, rect)
  end

  defp scrollbar(%{scrolled: true, scroll: %{total: t, viewport: v, offset: o}}),
    do: [%Overlay{kind: :scrollbar, args: %{total: t, viewport: v, offset: o}}]

  defp scrollbar(_), do: []

  defp selection(%{selection: %{pane: id} = sel}, id, rect, %{scroll: scroll}),
    do: List.wrap(Selection.overlay(sel, scroll, rect.w, rect.h))

  defp selection(_p, _id, _rect, _facts), do: []

  defp hover(%{hover: %{pane: id, id: lid, from: from, to: to}}, id),
    do: [%Overlay{kind: :link_hover, args: %{id: lid, from: from, to: to}}]

  defp hover(_p, _id), do: []

  # extension point: search matches and the copy cursor from `client.copy` (Task 8)
  defp copy(_client, _id, _rect), do: []
end
