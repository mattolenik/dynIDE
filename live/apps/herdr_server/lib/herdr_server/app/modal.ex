defmodule HerdrServer.App.Modal.Kind do
  @moduledoc """
  A modal kind (`App.Modal.Confirm`, `Prompt`, `Menu`; Task 8 adds settings, onboarding
  and keybinds). Callbacks are pure. `key/3` and `chrome/4` get the modal and the app
  with that modal already popped, so an action they run sees the rest of the stack and
  may push a new modal of its own. Results:

    * `{:keep, modal}`: the modal stays on top with the new state;
    * `{:keep, modal, app, effects}`: stays, with a changed app (live preview);
    * `{:replace, modal}`: another modal takes its place (a fresh id);
    * `{:close, app, effects}`: the modal is gone; `app` is what remains.

  `node/3` builds the modal's chrome node (`View.Modal` has the shared pieces); its id
  is set by `App.Modal.view/2`. `ignores_escape?/1` (optional, default false): Esc and
  backdrop clicks reach `key/3` / `chrome/4` instead of closing the modal.
  """

  alias HerdrScene.Scene.Node

  @type modal :: %{required(:kind) => atom, optional(atom) => term}
  @type app :: map
  @type result ::
          {:keep, modal}
          | {:keep, modal, app, [tuple]}
          | {:replace, modal}
          | {:close, app, [tuple]}

  @callback key(modal, tuple, app) :: result
  @callback chrome(modal, [term], {atom, map}, app) :: result
  @callback node(modal, app, %{cols: pos_integer, rows: pos_integer}) :: Node.t()
  @callback ignores_escape?(modal) :: boolean
  @optional_callbacks ignores_escape?: 1
end

defmodule HerdrServer.App.Modal do
  @moduledoc """
  The modal stack (`App.Focus.modal`, top first) and the routing into its top modal
  (pure). A modal is a plain map `%{kind: atom, id: pos_integer, ...kind fields}`; the
  kind names its module (`:confirm`, `:prompt`, `:menu`, or a module implementing
  `App.Modal.Kind` itself). Callbacks inside modals are `{M, F, A}`, never funs.

    * `key/2`: releases are dropped; Esc closes the top modal (unless its kind
      `ignores_escape?`), every other key goes to the kind.
    * `paste/2`: a top `:prompt`'s field gets the text; other kinds ignore it.
    * `chrome/3`: `[{:modal | :menu, depth} | rest]` for the top's depth only (a stale
      depth is a no-op); `[_, :backdrop]` clicks close like Esc; other paths go to the
      kind's `chrome/4` with `rest`.
    * `view/2`: the top modal's node (ids `{:modal, depth}` / `{:menu, depth}` with
      `depth = length(stack) - 1`), or nil.

  Keys never reach a pane while the stack is non-empty: `App.Actions` routes them here,
  and the Store's fast path needs `modal == []`.
  """

  alias HerdrScene.Scene.Node
  alias HerdrServer.App.Modal.{Confirm, Menu, Prompt, TextField}

  @kinds %{confirm: Confirm, prompt: Prompt, menu: Menu}

  @type modal :: HerdrServer.App.Modal.Kind.modal()

  @doc "Pushes `modal` on top with a fresh id."
  @spec push(map, map) :: map
  def push(app, modal) do
    id = (top_id(app.focus.modal) || 0) + 1
    update_in(app.focus.modal, &[Map.put(modal, :id, id) | &1])
  end

  @spec pop(map) :: map
  def pop(%{focus: %{modal: [_ | rest]}} = app), do: put_in(app.focus.modal, rest)
  def pop(app), do: app

  @spec top(map) :: modal | nil
  def top(%{focus: %{modal: [m | _]}}), do: m
  def top(_app), do: nil

  @doc "True when the top modal takes every key, prefix included (`Client.Session` bypass)."
  @spec capturing?(map) :: boolean
  def capturing?(%{modal: [%{capture: true} | _]}), do: true
  def capturing?(_focus), do: false

  @spec key(map, tuple) :: {map, [tuple]}
  def key(app, {:key, %{event: :release}}), do: {app, []}

  def key(%{focus: %{modal: [m | _]}} = app, {:key, %{key: :escape, mods: []}} = ev) do
    if ignores_escape?(m), do: run(app, &mod(m).key(m, ev, &1)), else: {pop(app), []}
  end

  def key(%{focus: %{modal: [m | _]}} = app, ev), do: run(app, &mod(m).key(m, ev, &1))
  def key(app, _ev), do: {app, []}

  @spec paste(map, binary) :: {map, [tuple]}
  def paste(%{focus: %{modal: [%{kind: :prompt} = m | rest]}} = app, bin),
    do: {put_in(app.focus.modal, [%{m | field: TextField.insert(m.field, bin)} | rest]), []}

  def paste(app, _bin), do: {app, []}

  @spec chrome(map, [term], {atom, map}) :: {map, [tuple]}
  def chrome(%{focus: %{modal: [m | _] = stack}} = app, [{tag, d} | rest], action)
      when tag in [:modal, :menu] do
    cond do
      d != length(stack) - 1 -> {app, []}
      rest == [:backdrop] -> backdrop(app, m, action)
      rest == [] -> {app, []}
      true -> run(app, &mod(m).chrome(m, rest, action, &1))
    end
  end

  def chrome(app, _path, _action), do: {app, []}

  @spec view(map, %{cols: pos_integer, rows: pos_integer}) :: Node.t() | nil
  def view(%{focus: %{modal: [m | _] = stack}} = app, size) do
    node = mod(m).node(m, app, size)
    tag = if node.role == :menu, do: :menu, else: :modal
    %{node | id: {tag, length(stack) - 1}}
  end

  def view(_app, _size), do: nil

  # --- helpers ---

  defp backdrop(app, m, {:click, _} = action) do
    if ignores_escape?(m),
      do: run(app, &mod(m).chrome(m, [:backdrop], action, &1)),
      else: {pop(app), []}
  end

  defp backdrop(app, _m, _action), do: {app, []}

  # the kind sees the app without its modal; :keep puts it back with the same id
  defp run(%{focus: %{modal: [m | _]}} = app, fun) do
    rest = pop(app)

    case fun.(rest) do
      {:keep, new} ->
        {update_in(rest.focus.modal, &[Map.put(new, :id, m.id) | &1]), []}

      {:keep, new, app2, effects} ->
        {update_in(app2.focus.modal, &[Map.put(new, :id, m.id) | &1]), effects}

      {:replace, new} ->
        {push(rest, new), []}

      {:close, app2, effects} ->
        {app2, effects}
    end
  end

  defp ignores_escape?(m) do
    k = mod(m)
    Code.ensure_loaded?(k) and function_exported?(k, :ignores_escape?, 1) and k.ignores_escape?(m)
  end

  defp mod(%{kind: kind}), do: Map.get(@kinds, kind, kind)

  defp top_id([%{id: id} | _]), do: id
  defp top_id(_), do: nil
end
