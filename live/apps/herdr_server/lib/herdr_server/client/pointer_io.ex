defmodule HerdrServer.Client.PointerIo do
  @moduledoc """
  The impure end of `Client.Pointer`, run by `Client.Session` (through
  `HerdrReload.Guard`). `context/3` reads what `Pointer.resolve/3` needs for the pane
  under the pointer and the gesture's pane only (live modes and scrollbar from the vt,
  rows from `Pane.Rows`); `run/3` executes the actions that touch the Store, panes,
  kernel or client, and returns the pointer (changed only when a ctrl+click found no
  link: the swallowed press is replayed and its release no longer swallowed) and the
  notices for the session to show. Timers and repaints stay in the session.
  `copy_context/2` is the same for `Client.CopyMode`, whose actions `run/3` executes too.
  """

  alias HerdrServer.App.{Actions, Store}
  alias HerdrServer.Client.{Links, Pointer}
  alias HerdrServer.Kernel
  alias HerdrServer.Pane.{Facts, Input, Rows, Server}
  alias HerdrServer.Pane.Links, as: PaneLinks
  alias HerdrServer.Plugins.Links, as: PluginLinks

  @tracking [:mouse_x10, :mouse_normal, :mouse_button, :mouse_any]

  @doc "The resolve context for `ev` (a `{:mouse, m}` or nil for an autoscroll tick)."
  @spec context(Pointer.t(), tuple | nil, map | nil) :: map
  def context(p, ev, scene) do
    # popup panes first (topmost last in the scene): they cover the panes under them
    {popups, base} =
      Enum.split_with((scene && scene.panes) || [], &(Map.get(&1, :layer) == :popup))

    panes = for pane <- Enum.reverse(popups) ++ base, do: %{id: pane.id, rect: pane.rect}
    ids = Enum.uniq([hit(panes, ev) | active(p)]) -- [nil]

    %{
      panes: panes,
      focused: scene && scene.focus.pane,
      info: ids |> Enum.map(&{&1, info(&1)}) |> Enum.reject(&(elem(&1, 1) == nil)) |> Map.new(),
      now_ms: System.monotonic_time(:millisecond),
      scroll_lines: 3,
      copy_on_select: true
    }
  end

  defp hit(panes, {:mouse, %{x: x, y: y}}) do
    Enum.find_value(panes, fn %{id: id, rect: r} ->
      if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h, do: id
    end)
  end

  defp hit(_panes, _ev), do: nil

  defp active(p) do
    for %{pane: id} <- [p.press, p.drag, p.autoscroll], do: id
  end

  defp info(id) do
    case vt(id) do
      {:ok, vt} -> info(id, vt)
      :error -> nil
    end
  end

  defp info(id, vt) do
    %{
      tracking: Enum.any?(@tracking, &mode?(vt, &1)),
      any_motion: mode?(vt, :mouse_any),
      alt_screen: mode?(vt, :alt_screen),
      alternate_scroll: mode?(vt, :alternate_scroll),
      scroll: Kernel.vt().scrollbar(vt),
      rows:
        case Rows.fetch(id) do
          {_gen, rows, _cursor} -> rows
          nil -> nil
        end
    }
  end

  @doc """
  Pane `id`'s pointer-relevant facts: `%{alt_screen}` from `Pane.Facts` (one ETS read),
  plus the live scroll `offset` when `offset?`; nil for an unknown pane.
  """
  @spec facts(term, boolean) :: map | nil
  def facts(id, offset?) do
    case Facts.get(id) do
      %{alt_screen: alt} ->
        if offset?, do: with_offset(%{alt_screen: alt}, id), else: %{alt_screen: alt}

      _ ->
        nil
    end
  end

  @doc """
  `pane_id => %{scrolled, scroll, alt_screen}` for `ids` that are scrolled (one ETS read
  each) plus `live` (a pane or a list: the selection's and copy mode's), whose live
  scrollbar is read when it is not scrolled (its `Facts.scroll` is stale). Everything
  else is left out.
  """
  @spec scene_facts([term], term | [term]) :: map
  def scene_facts(ids, live) do
    live = List.wrap(live)

    Enum.reduce(Enum.uniq(ids ++ live), %{}, &scene_fact(&2, &1, Facts.get(&1), &1 in live))
  end

  defp scene_fact(acc, id, %{scrolled: true} = f, _live?),
    do: Map.put(acc, id, Map.take(f, [:scrolled, :scroll, :alt_screen]))

  defp scene_fact(acc, id, %{} = f, true), do: Map.put(acc, id, live(f, id))
  defp scene_fact(acc, _id, _f, _live?), do: acc

  defp live(f, id) do
    scroll =
      case vt(id) do
        {:ok, vt} -> Kernel.vt().scrollbar(vt)
        :error -> f.scroll
      end

    %{scrolled: f.scrolled, alt_screen: f.alt_screen, scroll: scroll}
  end

  defp with_offset(facts, id) do
    case vt(id) do
      {:ok, vt} -> Map.put(facts, :offset, Kernel.vt().scrollbar(vt).offset)
      :error -> facts
    end
  end

  @doc """
  `Client.CopyMode`'s context for pane `id` of `scene`: its size, live scrollbar, a
  `screen_rows` reader `{m, f, a}` and the visible terminal cursor (viewport cell, nil
  when hidden or scrolled back); nil when the pane or its vt is gone.
  """
  @spec copy_context(term, map | nil) :: map | nil
  def copy_context(id, scene) do
    with %{rect: r} <- scene && Enum.find(scene.panes, &(&1.id == id)),
         {:ok, vt} <- vt(id) do
      scroll = Kernel.vt().scrollbar(vt)

      cursor =
        case Kernel.vt().cursor(vt) do
          %{visible: true, x: x, y: y} when scroll.offset >= scroll.total - r.h -> {x, y}
          _ -> nil
        end

      %{scroll: scroll, h: r.h, w: r.w, read: {Kernel.vt(), :screen_rows, [vt]}, cursor: cursor}
    else
      _ -> nil
    end
  end

  @doc """
  Executes `actions` for the session of client `io.client` (driving size `io.size`).
  Returns `{pointer, notices}`.
  """
  @spec run([term], Pointer.t(), %{client: pid, size: map}) :: {Pointer.t(), [map]}
  def run(actions, p, io) do
    Enum.reduce(actions, {p, []}, fn action, {p, notices} ->
      case act(action, p, io) do
        {:notice, n} -> {p, notices ++ [n]}
        %Pointer{} = p -> {p, notices}
        _done -> {p, notices}
      end
    end)
  end

  defp act({:forward, ev}, _p, io), do: Store.event(ev, io.size)
  defp act({:focus, id}, _p, io), do: Store.run({Actions, :focus_pane, [id]}, io.size)
  defp act({:scroll, id, delta}, _p, _io), do: Server.scroll(id, {:delta, delta})
  defp act({:scroll_top, id, row}, _p, _io), do: Server.scroll(id, {:top, row})
  defp act({:scroll_bottom, id}, _p, _io), do: Server.scroll(id, :bottom)
  defp act({:notice, n}, _p, _io), do: {:notice, n}
  defp act({:keys, id, keys}, _p, _io), do: Enum.each(keys, &Input.key(&1, id))

  defp act({:copy, id, from, to}, _p, io) do
    with {:ok, vt} <- vt(id),
         text when is_binary(text) and text != "" <-
           Kernel.vt().read_text(vt, {:selection, from, to}) do
      send(io.client, {:clipboard, %{text: text, source: :selection}})
      {:notice, %{level: :info, text: "copied to clipboard"}}
    end
  end

  defp act({:open, id, %{url: url} = t}, _p, io), do: open(url, id, t, io)

  defp act({:open, id, %{id: _, x: x, y: y} = t}, p, io) do
    case vt(id) do
      {:ok, vt} -> opened(Kernel.vt().link_at(vt, x, y), id, t, p, io)
      _ -> :ok
    end
  end

  defp act(_other, _p, _io), do: :ok

  # no link under the press after all: a tracking child gets the press (and then its
  # release); on a non-tracking pane the click is dropped
  defp opened(nil, _id, _t, %{swallow_up: %{tracking: true, pane: id, local: ev}} = p, _io) do
    Input.mouse(ev, id)
    %{p | swallow_up: nil}
  end

  defp opened(%{uri: uri}, id, t, _p, io), do: open(uri, id, t, io)
  defp opened(_none, _id, _t, _p, _io), do: :ok

  # a plugin link handler first (any scheme); unhandled, only http(s) opens on the client.
  # A failed handler launch has shown its alert and does not fall back to the browser.
  defp open(url, id, t, io) when is_binary(url) do
    if PluginLinks.dispatch(url, t[:mods] || [], id) == :unhandled and Links.safe?(url),
      do: send(io.client, {:open_url, url})

    :ok
  end

  defp open(_url, _id, _t, _io), do: :ok

  defp vt(id), do: PaneLinks.vt(id)

  defp mode?(vt, mode) do
    case Kernel.vt().mode(vt, mode) do
      {:stale, b} -> b
      b -> b
    end
  end
end
