defmodule HerdrScene.Scene do
  @moduledoc """
  The frontend-neutral scene a server pushes to every client.

  Contract rules:

    * Chrome nodes carry roles, text, props and theme tokens, never glyphs,
      colours or escape sequences. The server never produces a cell.
    * Tokens are resolved per client by its own theme.
    * Layout is in cells: all rects are in the scene's `size` grid.
    * Cursor, selection, dim and link hover are semantic overlays.
    * Pane contents are either a ref (`{:ref, pane_id, gen}`, resolved by the
      client) or inline rows. `Pane.rect` is the content rect.

  `validate/1` checks the whole scene and returns path-named errors such as
  `"panes[1].rect: outside scene size"`. Node `props` are open and not checked.
  """

  alias HerdrScene.Scene.{Node, Overlay, Pane}

  @roles [
    :root,
    :status,
    :tabs,
    :tab,
    :text,
    :button,
    :divider,
    :group,
    :spacer,
    :sidebar,
    :modal
  ]
  @tokens [:default, :accent, :muted, :focus, :warning, :error, :inverse]
  @shapes [:block, :underline, :bar]
  @edges [:top, :bottom, :left, :right]

  @type role ::
          :root
          | :status
          | :tabs
          | :tab
          | :text
          | :button
          | :divider
          | :group
          | :spacer
          | :sidebar
          | :modal
  @type token :: :default | :accent | :muted | :focus | :warning | :error | :inverse
  @type shape :: :block | :underline | :bar
  @type rect :: %{x: non_neg_integer, y: non_neg_integer, w: non_neg_integer, h: non_neg_integer}
  @type t :: %__MODULE__{
          size: %{cols: pos_integer, rows: pos_integer},
          panes: [Pane.t()],
          chrome: Node.t() | nil,
          focus: %{pane: pos_integer | nil, chrome: [term] | nil},
          cursor: %{x: non_neg_integer, y: non_neg_integer, shape: shape} | nil
        }

  @enforce_keys [:size]
  defstruct [:size, :chrome, :cursor, panes: [], focus: %{pane: nil, chrome: nil}]

  @spec roles() :: [role]
  def roles, do: @roles

  @spec tokens() :: [token]
  def tokens, do: @tokens

  @spec validate(term) :: :ok | {:error, [binary]}
  def validate(%__MODULE__{size: size} = scene) do
    case size_errors(size) do
      [] -> finish(scene_errors(scene))
      errs -> {:error, errs}
    end
  end

  def validate(_), do: {:error, ["scene: not a %HerdrScene.Scene{}"]}

  defp finish([]), do: :ok
  defp finish(errs), do: {:error, errs}

  defp size_errors(%{cols: c, rows: r}) when is_integer(c) and c > 0 and is_integer(r) and r > 0,
    do: []

  defp size_errors(_), do: ["size: expected %{cols: pos_integer, rows: pos_integer}"]

  defp scene_errors(scene) do
    ids = Enum.map(scene.panes, & &1.id)

    pane_errors(scene) ++
      chrome_errors(scene) ++
      focus_errors(scene.focus, ids, scene.chrome) ++
      cursor_errors("cursor", scene.cursor)
  end

  # panes

  defp pane_errors(%{panes: panes} = scene) when is_list(panes) do
    panes
    |> Enum.with_index()
    |> Enum.flat_map(fn {pane, i} ->
      path = "panes[#{i}]"
      dup = if dup_id?(panes, i), do: ["#{path}.id: duplicate #{inspect(pane.id)}"], else: []
      dup ++ one_pane_errors(path, pane, scene.size)
    end)
  end

  defp pane_errors(_), do: ["panes: not a list"]

  defp dup_id?(panes, i), do: Enum.at(panes, i).id in (panes |> Enum.take(i) |> Enum.map(& &1.id))

  defp one_pane_errors(path, %Pane{} = p, size) do
    id = if is_integer(p.id) and p.id > 0, do: [], else: ["#{path}.id: expected pos_integer"]

    id ++
      rect_errors("#{path}.rect", p.rect, size) ++
      border_errors("#{path}.border", p.border, size) ++
      rows_errors("#{path}.rows", p) ++
      pane_cursor_errors("#{path}.cursor", p.cursor) ++
      overlays_errors("#{path}.overlays", p.overlays) ++
      if(is_list(p.graphics) and Enum.all?(p.graphics, &is_map/1),
        do: [],
        else: ["#{path}.graphics: expected list of maps"]
      )
  end

  defp one_pane_errors(path, _, _), do: ["#{path}: not a %Pane{}"]

  defp rect_errors(path, %{x: x, y: y, w: w, h: h} = r, %{cols: cols, rows: rows})
       when map_size(r) == 4 do
    cond do
      not Enum.all?([x, y, w, h], &(is_integer(&1) and &1 >= 0)) ->
        ["#{path}: expected non-negative integers x, y, w, h"]

      x + w > cols or y + h > rows ->
        ["#{path}: outside scene size"]

      true ->
        []
    end
  end

  defp rect_errors(path, _, _), do: ["#{path}: expected %{x, y, w, h}"]

  defp border_errors(_, nil, _), do: []

  defp border_errors(path, %{rect: rect, edges: edges, title: title}, size) do
    rect_errors("#{path}.rect", rect, size) ++
      if(is_list(edges) and Enum.all?(edges, &(&1 in @edges)),
        do: [],
        else: ["#{path}.edges: expected subset of #{inspect(@edges)}"]
      ) ++
      if(is_nil(title) or is_binary(title),
        do: [],
        else: ["#{path}.title: expected binary or nil"]
      )
  end

  defp border_errors(path, _, _), do: ["#{path}: expected %{rect, edges, title} or nil"]

  defp rows_errors(path, %Pane{id: id, rows: {:ref, ref_id, gen}}) do
    cond do
      not (is_integer(gen) and gen >= 0) -> ["#{path}: gen must be non_neg_integer"]
      ref_id != id -> ["#{path}: ref id #{inspect(ref_id)} does not match pane #{inspect(id)}"]
      true -> []
    end
  end

  defp rows_errors(path, %Pane{rows: {:inline, rows}}) do
    if is_list(rows) and
         Enum.all?(rows, &match?({n, b} when is_integer(n) and n >= 0 and is_binary(b), &1)),
       do: [],
       else: ["#{path}: inline rows must be [{non_neg_integer, binary}]"]
  end

  defp rows_errors(path, _), do: ["#{path}: expected {:ref, id, gen} or {:inline, rows}"]

  defp pane_cursor_errors(_, nil), do: []

  defp pane_cursor_errors(path, %{visible: v} = c) when is_boolean(v),
    do: cursor_errors(path, Map.delete(c, :visible))

  defp pane_cursor_errors(path, _), do: ["#{path}: expected %{x, y, shape, visible}"]

  defp cursor_errors(_, nil), do: []

  defp cursor_errors(_path, %{x: x, y: y, shape: s})
       when is_integer(x) and x >= 0 and is_integer(y) and y >= 0 and s in @shapes,
       do: []

  defp cursor_errors(path, _), do: ["#{path}: expected %{x, y, shape: #{inspect(@shapes)}}"]

  defp overlays_errors(path, overlays) when is_list(overlays) do
    overlays
    |> Enum.with_index()
    |> Enum.flat_map(fn {o, i} ->
      if overlay_ok?(o), do: [], else: ["#{path}[#{i}]: invalid overlay #{inspect(o)}"]
    end)
  end

  defp overlays_errors(path, _), do: ["#{path}: not a list"]

  defp overlay_ok?(%Overlay{kind: :selection, args: %{from: f, to: t} = a}),
    do: map_size(a) == 2 and pos?(f) and pos?(t)

  defp overlay_ok?(%Overlay{kind: :dim, args: %{reason: :inactive} = a}), do: map_size(a) == 1

  defp overlay_ok?(%Overlay{kind: :link_hover, args: %{id: id, from: f, to: t} = a}),
    do: map_size(a) == 3 and nat?(id) and pos?(f) and pos?(t)

  defp overlay_ok?(%Overlay{kind: :scrollbar, args: %{total: a, viewport: b, offset: c} = m}),
    do: map_size(m) == 3 and nat?(a) and nat?(b) and nat?(c)

  defp overlay_ok?(_), do: false

  defp nat?(n), do: is_integer(n) and n >= 0
  defp pos?({x, y}), do: nat?(x) and nat?(y)
  defp pos?(_), do: false

  # chrome

  defp chrome_errors(%{chrome: nil}), do: []
  defp chrome_errors(%{chrome: %Node{} = n, size: size}), do: node_errors("chrome", n, size)
  defp chrome_errors(_), do: ["chrome: expected %Node{} or nil"]

  defp node_errors(path, %Node{} = n, size) do
    role = if n.role in @roles, do: [], else: ["#{path}.role: unknown #{inspect(n.role)}"]

    token =
      if is_nil(n.token) or n.token in @tokens,
        do: [],
        else: ["#{path}.token: unknown #{inspect(n.token)}"]

    text =
      if is_nil(n.text) or is_binary(n.text),
        do: [],
        else: ["#{path}.text: expected binary or nil"]

    props = if is_map(n.props), do: [], else: ["#{path}.props: expected map"]
    rect = if n.rect == nil, do: [], else: rect_errors("#{path}.rect", n.rect, size)

    role ++ token ++ text ++ props ++ rect ++ children_errors(path, n.children, size)
  end

  defp node_errors(path, _, _), do: ["#{path}: not a %Node{}"]

  defp children_errors(path, children, size) when is_list(children) do
    children
    |> Enum.with_index()
    |> Enum.flat_map(fn {c, i} ->
      cpath = "#{path}.children[#{i}]"
      dup = if sibling_dup?(children, i), do: ["#{cpath}.id: duplicate sibling id"], else: []
      dup ++ node_errors(cpath, c, size)
    end)
  end

  defp children_errors(path, _, _), do: ["#{path}.children: not a list"]

  defp sibling_dup?(children, i) do
    case Enum.at(children, i) do
      %Node{id: id} -> id in (children |> Enum.take(i) |> Enum.flat_map(&node_id/1))
      _ -> false
    end
  end

  defp node_id(%Node{id: id}), do: [id]
  defp node_id(_), do: []

  # focus

  defp focus_errors(%{pane: pane, chrome: path}, ids, chrome) do
    pane_err =
      if is_nil(pane) or pane in ids, do: [], else: ["focus.pane: no pane #{inspect(pane)}"]

    pane_err ++ focus_chrome_errors(path, chrome)
  end

  defp focus_errors(_, _, _), do: ["focus: expected %{pane, chrome}"]

  defp focus_chrome_errors(nil, _), do: []

  defp focus_chrome_errors(path, %Node{} = chrome) when is_list(path) do
    if Node.find(chrome, path), do: [], else: ["focus.chrome: path #{inspect(path)} not found"]
  end

  defp focus_chrome_errors(path, _), do: ["focus.chrome: path #{inspect(path)} not found"]
end
