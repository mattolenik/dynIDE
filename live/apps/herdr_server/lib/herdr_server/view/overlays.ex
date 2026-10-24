defmodule HerdrServer.View.Overlays do
  @moduledoc """
  Pure: semantic `Scene.Overlay`s of one pane from the client's own state.

  Order: `:scrollbar` (pane scrolled back, from `client.facts`), `:selection`
  (`Client.Selection.overlay/4` through the facts' scroll offset), `:link_hover`
  (`pointer.hover` on this pane), then copy mode's selection, search matches and cursor
  (`Client.CopyMode.overlays/4` from `client.copy`, through the facts' offset or the
  mode's own viewport top).
  No state for the pane means `[]` without any per-row work.
  """

  alias HerdrScene.Scene.Overlay
  alias HerdrServer.Client.{CopyMode, Selection}

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

  defp copy(%{copy: %CopyMode{pane: id} = copy, facts: facts}, id, rect) do
    offset =
      case facts do
        %{^id => %{scroll: %{offset: o}}} -> o
        _ -> copy.top
      end

    CopyMode.overlays(copy, offset, rect.w, rect.h)
  end

  defp copy(_client, _id, _rect), do: []
end
