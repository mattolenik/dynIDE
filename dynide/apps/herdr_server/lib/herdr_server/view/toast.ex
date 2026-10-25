defmodule HerdrServer.View.Toast do
  @moduledoc """
  Pure: one client's toasts (`Client.Toasts`, newest first) as `:toast` regions at the
  bottom-right of the pane area, the newest lowest and older ones stacked upward; those
  that no longer fit are left out. Each card is `max(title, body) + 6` cells wide and 4
  high (both clamped to the area), `text` the title, `token` the level's dot colour
  (`:error` attention, `:info` done, `:accent` otherwise), one `:text` `:body` child.
  """

  alias HerdrScene.Scene.Node

  @h 4

  @spec nodes([map], %{x: integer, y: integer, w: integer, h: integer}) :: [Node.t()]
  def nodes(toasts, area) do
    h = min(@h, area.h)

    toasts
    |> Enum.with_index(1)
    |> Enum.map(fn {t, i} -> {t, area.y + area.h - h * i} end)
    |> Enum.filter(fn {_, y} -> h > 0 and area.w > 0 and y >= area.y end)
    |> Enum.map(fn {t, y} -> node(t, area, y, h) end)
  end

  defp node(t, area, y, h) do
    w = min(max(len(t.title), len(t.body)) + 6, area.w)

    %Node{
      role: :toast,
      id: {:toast, t.id},
      rect: %{x: area.x + area.w - w, y: y, w: w, h: h},
      text: t.title,
      token: token(t.level),
      props: %{level: t.level, pane: t.pane},
      children: [%Node{role: :text, id: :body, text: t.body}]
    }
  end

  defp len(nil), do: 0
  defp len(s), do: String.length(s)

  defp token(:attention), do: :error
  defp token(:done), do: :info
  defp token(_), do: :accent
end
