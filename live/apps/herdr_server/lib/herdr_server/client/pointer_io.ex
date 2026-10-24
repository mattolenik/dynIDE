defmodule HerdrServer.Client.PointerIo do
  @moduledoc """
  The impure end of `Client.Pointer`, run by `Client.Session` (through
  `HerdrReload.Guard`). `context/3` reads what `Pointer.resolve/3` needs for the pane
  under the pointer and the gesture's pane only (live modes and scrollbar from the vt,
  rows from `Pane.Rows`); `run/3` executes the actions that touch the Store, panes,
  kernel or client, and returns the pointer (changed only when a ctrl+click found no
  link: the swallowed press is replayed and its release no longer swallowed) and the
  notices for the session to show. Timers and repaints stay in the session.
  """

  alias HerdrServer.App.{Actions, Store}
  alias HerdrServer.Client.{Links, Pointer}
  alias HerdrServer.Kernel
  alias HerdrServer.Pane.{Facts, Input, Rows, Server}

  @tracking [:mouse_x10, :mouse_normal, :mouse_button, :mouse_any]

  @doc "The resolve context for `ev` (a `{:mouse, m}` or nil for an autoscroll tick)."
  @spec context(Pointer.t(), tuple | nil, map | nil) :: map
  def context(p, ev, scene) do
    panes = for pane <- (scene && scene.panes) || [], do: %{id: pane.id, rect: pane.rect}
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
  each) plus `sel_pane`, whose live scrollbar is read when it is not scrolled (its
  `Facts.scroll` is stale). Everything else is left out.
  """
  @spec scene_facts([term], term) :: map
  def scene_facts(ids, sel_pane) do
    Enum.reduce(Enum.uniq(ids ++ List.wrap(sel_pane)), %{}, fn id, acc ->
      case Facts.get(id) do
        %{scrolled: true} = f -> Map.put(acc, id, Map.take(f, [:scrolled, :scroll, :alt_screen]))
        %{} = f when id == sel_pane -> Map.put(acc, id, live(f, id))
        _ -> acc
      end
    end)
  end

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
  defp act({:keys, id, keys}, _p, _io), do: Enum.each(keys, &Input.key(&1, id))

  defp act({:copy, id, from, to}, _p, io) do
    with {:ok, vt} <- vt(id),
         text when is_binary(text) and text != "" <-
           Kernel.vt().read_text(vt, {:selection, from, to}) do
      send(io.client, {:clipboard, %{text: text, source: :selection}})
      {:notice, %{level: :info, text: "copied to clipboard"}}
    end
  end

  defp act({:open, _id, %{url: url}}, _p, io), do: open(url, io)

  defp act({:open, id, %{id: _, x: x, y: y}}, p, io) do
    case vt(id) do
      {:ok, vt} -> opened(Kernel.vt().link_at(vt, x, y), p, io)
      _ -> :ok
    end
  end

  defp act(_other, _p, _io), do: :ok

  # no link under the press after all: a tracking child gets the press (and then its
  # release); on a non-tracking pane the click is dropped
  defp opened(nil, %{swallow_up: %{tracking: true, pane: id, local: ev}} = p, _io) do
    Input.mouse(ev, id)
    %{p | swallow_up: nil}
  end

  defp opened(%{uri: uri}, _p, io), do: open(uri, io)
  defp opened(_none, _p, _io), do: :ok

  defp open(url, io) do
    if is_binary(url) and Links.safe?(url), do: send(io.client, {:open_url, url})
    :ok
  end

  defp vt(id) do
    with kid when kid != nil <- Rows.kernel_id(id),
         {:ok, %{vt: vt}} <- Kernel.keeper().lookup(kid),
         do: {:ok, vt},
         else: (_ -> :error)
  end

  defp mode?(vt, mode) do
    case Kernel.vt().mode(vt, mode) do
      {:stale, b} -> b
      b -> b
    end
  end
end
