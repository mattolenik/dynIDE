defmodule HerdrServer.App.Modal.Popup do
  @moduledoc """
  herdr's popup pane (D4): a floating terminal over the active tab that does not touch
  the layout. `%{kind: :popup, pane: id, width, height, title, layout_gen}`; at most one
  is open (herdr: "popup already open").

    * `open/3` (plain function, also the entry point for plugin popups): pushes the
      modal for an already allocated pane id and returns the pane's terminal size; the
      caller spawns the pane (`{:spawn, id, size, opts}`, `identity: false`: herdr gives
      a popup no pane identity).
    * Every key (prefix and Esc included, `capture: true`) and every paste goes to the
      popup pane (`App.Modal` routes them before its release / Esc handling); a mouse
      event inside the popup's content rect goes to it, pane-relative.
    * The pane's exit (`exited/2`) or `close/1` (`popup.close`) removes the modal and
      closes the pane (`{:close, id}`).
    * The popup pane is not in `session.panes` or any layout (not persisted, listed or
      detected). The Store resizes it to `rects/1` and bumps its `layout_gen` (`bump/2`).
    * Scene: no chrome node (`node/3` is nil, so no dim and no backdrop); `View` adds the
      pane with `layer: :popup`, an all-edges border titled `title`, and focus.

  Sizing (`size/2`, herdr's `popup_size.rs`): `width` / `height` are nil (half the area),
  `{:cells, n}` or `{:percent, p}` (`parse/1` takes herdr's config values: an integer or
  `"N%"`), of the outer box including the 1-cell border; at least 6x4 and at most the
  area, centred. The terminal is the inner box, one column narrower when wider than 4.
  """

  @behaviour HerdrServer.App.Modal.Kind

  alias HerdrServer.App.Modal

  @type spec_size :: nil | {:cells, non_neg_integer} | {:percent, 1..100}
  @type rect :: %{x: integer, y: integer, w: non_neg_integer, h: non_neg_integer}

  @size_error "must be a number of cells or a percentage like 80%"

  @doc "herdr's config value: an integer cell count, `\"N%\"` (1-100) or nil."
  @spec parse(term) :: {:ok, spec_size} | {:error, binary}
  def parse(nil), do: {:ok, nil}
  def parse(n) when is_integer(n) and n in 0..65_535, do: {:ok, {:cells, n}}

  def parse(s) when is_binary(s) do
    with true <- String.ends_with?(s, "%"),
         {p, "%"} <- Integer.parse(s),
         true <- p in 1..100 do
      {:ok, {:percent, p}}
    else
      _ -> {:error, @size_error}
    end
  end

  def parse(_), do: {:error, @size_error}

  @doc "Outer and inner (terminal) rects in `area`, or nil when the area is too small."
  @spec size(%{width: spec_size, height: spec_size}, rect) :: %{outer: rect, inner: rect} | nil
  def size(%{width: width, height: height}, area) do
    w = width |> resolve(area.w, max(div(area.w, 2), 6)) |> max(6) |> min(area.w)
    h = height |> resolve(area.h, max(div(area.h, 2), 4)) |> max(4) |> min(area.h)

    if w < 6 or h < 4 do
      nil
    else
      x = area.x + div(area.w - w, 2)
      y = area.y + div(area.h - h, 2)
      iw = w - 2
      cols = if iw <= 4, do: iw, else: iw - 1
      %{outer: %{x: x, y: y, w: w, h: h}, inner: %{x: x + 1, y: y + 1, w: cols, h: h - 2}}
    end
  end

  defp resolve(nil, _avail, default), do: default
  defp resolve({:cells, n}, _avail, _default), do: n
  defp resolve({:percent, p}, avail, _default), do: div(avail * p, 100)

  @doc """
  Opens a popup for pane `pane` (an id the caller allocated) sized by `spec` (`width`,
  `height`, optional `title`) in the app's pane area. Returns the terminal size to spawn.
  """
  @spec open(map, pos_integer, map) ::
          {:ok, map, %{cols: pos_integer, rows: pos_integer}} | {:error, binary}
  def open(app, pane, spec) do
    spec = Map.merge(%{width: nil, height: nil, title: nil}, spec)
    geo = size(spec, app.session.area)

    cond do
      find(app) != nil ->
        {:error, "popup already open"}

      geo == nil ->
        {:error, "terminal area too small for popup"}

      true ->
        modal = %{
          kind: :popup,
          pane: pane,
          width: spec.width,
          height: spec.height,
          title: spec.title || "popup",
          layout_gen: 0,
          capture: true
        }

        {:ok, Modal.push(app, modal), %{cols: geo.inner.w, rows: geo.inner.h}}
    end
  end

  @doc "The open popup modal (top first), or nil."
  @spec find(map) :: map | nil
  def find(%{focus: %{modal: stack}}), do: Enum.find(stack, &(&1.kind == :popup))
  def find(_app), do: nil

  @doc "Closes the open popup (`popup.close`): `{:close, pane}`; none open is a no-op."
  @spec close(map) :: {map, [tuple]}
  def close(app) do
    case find(app) do
      nil -> {app, []}
      m -> {drop(app, m.pane), [{:close, m.pane}]}
    end
  end

  @doc "Pane `id` exited: the app without its popup when `id` is the popup's, else nil."
  @spec exited(map, pos_integer) :: {map, [tuple]} | nil
  def exited(app, id) do
    case find(app) do
      %{pane: ^id} -> {drop(app, id), [{:close, id}]}
      _ -> nil
    end
  end

  @doc "The popup pane's content rect in the app's pane area, as Layout rects (0 or 1)."
  @spec rects(map) :: [%{id: pos_integer, rect: rect}]
  def rects(app) do
    with %{} = m <- find(app), %{inner: r} <- size(m, app.session.area) do
      [%{id: m.pane, rect: r}]
    else
      _ -> []
    end
  end

  @doc "Bumps the popup pane's `layout_gen` (the Store resized it)."
  @spec bump(map, pos_integer) :: map
  def bump(app, id) do
    stack = Enum.map(app.focus.modal, &bump_one(&1, id))
    put_in(app.focus.modal, stack)
  end

  defp bump_one(%{kind: :popup, pane: id} = m, id), do: %{m | layout_gen: m.layout_gen + 1}
  defp bump_one(m, _id), do: m

  @doc "A mouse event for the popup pane when it is inside its content rect, else none."
  @spec mouse(map, tuple) :: {map, [tuple]}
  def mouse(app, {:mouse, m}) do
    case rects(app) do
      [%{id: id, rect: r}]
      when m.x >= r.x and m.x < r.x + r.w and m.y >= r.y and m.y < r.y + r.h ->
        {app, [{:mouse, id, {:mouse, %{m | x: m.x - r.x, y: m.y - r.y}}}]}

      _ ->
        {app, []}
    end
  end

  defp drop(app, id),
    do:
      put_in(
        app.focus.modal,
        Enum.reject(app.focus.modal, &match?(%{kind: :popup, pane: ^id}, &1))
      )

  # --- kind ---

  @impl true
  def key(m, ev, app), do: {:keep, m, app, [{:key, m.pane, ev}]}

  @impl true
  def chrome(m, _path, _action, _app), do: {:keep, m}

  @impl true
  def node(_m, _app, _size), do: nil

  @impl true
  def ignores_escape?(_m), do: true
end
