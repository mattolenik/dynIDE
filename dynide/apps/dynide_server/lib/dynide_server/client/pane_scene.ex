defmodule DynideServer.Client.PaneScene do
  @moduledoc """
  The one-pane scene of a pane-target socket conn (`terminal observe|attach`, R17): the
  pane at the origin, clipped to the client's size (the pane keeps the layout's size; the
  client pads), every visible row inline (`Client.Outbox` sends only changes), an empty
  root chrome node, focus on the pane and the host cursor by `Client.Session`'s rule.
  Pure.
  """

  alias DynideScene.{Cell, Scene}
  alias DynideScene.Scene.{Node, Pane}

  @spec build(pos_integer, {non_neg_integer, tuple, map | nil} | nil, %{
          cols: pos_integer,
          rows: pos_integer
        }) :: Scene.t()
  def build(id, fetched, %{cols: cols, rows: rows}) do
    {tuple, cursor} =
      case fetched do
        {_gen, t, c} -> {t, c}
        nil -> {{}, nil}
      end

    h = min(rows, tuple_size(tuple))
    w = if h > 0, do: min(cols, Cell.cols(elem(tuple, 0))), else: 0
    lines = for n <- 0..(h - 1)//1, do: {n, elem(tuple, n)}
    rect = %{x: 0, y: 0, w: w, h: h}
    pane = %Pane{id: id, rect: rect, rows: {:inline, lines}, cursor: cursor}

    %Scene{
      size: %{cols: cols, rows: rows},
      panes: [pane],
      chrome: %Node{role: :root, id: :root, children: []},
      focus: %{pane: id, chrome: nil},
      cursor: host_cursor(pane)
    }
  end

  # Client.Session's rule (not shared: Session is not edited in M16)
  defp host_cursor(%{cursor: %{visible: true} = c, rect: r}) when c.y < r.h and r.w > 0,
    do: %{x: r.x + min(c.x, r.w - 1), y: r.y + c.y, shape: c.shape}

  defp host_cursor(_pane), do: nil
end
