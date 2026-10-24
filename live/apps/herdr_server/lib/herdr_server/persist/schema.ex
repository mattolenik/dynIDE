defmodule HerdrServer.Persist.Schema do
  @moduledoc """
  Pure snapshot schema for session persistence: `capture/2` turns an app plus per-pane
  runtime facts into a plain, versioned snapshot; `restore/1` migrates, validates and
  rebuilds the app. `restore(capture(app, facts))` captures back to the same snapshot.

  Snapshot (v2):

      %{v: 2,
        session: %{workspaces: [%{id, name, active_tab,
                                  tabs: [%{id, name, layout: %{root, focus, prev_focus}}]}],
                   active_workspace, next_id, size: %{cols, rows}, area: %{x, y, w, h}},
        focus: %{pane: id | nil},
        ui: Map.from_struct(ui) without :keybinds, plain values only,
        panes: %{id => %{title, cwd, command, hidden}}}

  Not persisted: keybinds (restored as `Keybinds.default/0`), the modal stack (`[]`),
  pane `layout_gen` (0). The recorded command is metadata, never re-run.

  The app structs are built with `struct/2` at runtime, never as literals, so this module
  has no compile-time dependency on `App.Session`, `App.Focus` or `App.Ui`.

  Migrations: `migrate/2` takes a chain `%{from_v => {module, fun} | fun_atom}` (an atom
  names a function in this module). Each function takes the map at `from_v` and returns
  it at `from_v + 1`; `:v` is set to `from_v + 1` after each step. Registered: v1 -> v2
  (`v1_to_v2/1`) adds `session.size` with `App.Session`'s default.
  """

  alias HerdrServer.App.Keybinds

  @version 2
  @migrations %{1 => :v1_to_v2}

  @session HerdrServer.App.Session
  @focus HerdrServer.App.Focus
  @ui HerdrServer.App.Ui

  @type id :: pos_integer()
  @type tree :: {:pane, id()} | {:split, :horizontal | :vertical, float(), tree(), tree()}
  @type fact :: %{cwd: binary() | nil, command: [binary()] | nil, hidden: boolean()}
  @type facts :: %{id() => fact()}
  @type snapshot :: map()
  @type migrations :: %{non_neg_integer() => {module(), atom()} | atom()}

  @spec version() :: pos_integer()
  def version, do: @version

  # --- capture ---

  @spec capture(map(), facts()) :: snapshot()
  def capture(app, facts) do
    s = app.session

    %{
      v: @version,
      session: %{
        workspaces: Enum.map(s.workspaces, &capture_ws/1),
        active_workspace: s.active_workspace,
        next_id: s.next_id,
        size: Map.take(s.size, [:cols, :rows]),
        area: Map.take(s.area, [:x, :y, :w, :h])
      },
      focus: %{pane: app.focus.pane},
      ui: capture_ui(app.ui),
      panes: Map.new(s.panes, fn {id, meta} -> {id, capture_pane(meta, Map.get(facts, id))} end)
    }
  end

  defp capture_ws(ws) do
    %{
      id: ws.id,
      name: ws.name,
      active_tab: ws.active_tab,
      tabs: Enum.map(ws.tabs, &capture_tab/1)
    }
  end

  defp capture_tab(tab) do
    l = tab.layout

    %{
      id: tab.id,
      name: tab.name,
      layout: %{root: l.root, focus: l.focus, prev_focus: l.prev_focus}
    }
  end

  defp capture_ui(ui) do
    ui
    |> Map.from_struct()
    |> Map.delete(:keybinds)
    |> Map.filter(fn {_k, v} -> plain?(v) end)
  end

  defp capture_pane(meta, fact) do
    fact = fact || %{}

    %{
      title: Map.get(meta, :title),
      cwd: Map.get(fact, :cwd),
      command: Map.get(fact, :command),
      hidden: Map.get(fact, :hidden, false) == true
    }
  end

  # --- restore ---

  @doc """
  Migrates `snapshot` to the current version, validates it and rebuilds the app and the
  per-pane facts. Errors: `{:newer, v}`, `{:unknown_version, v}`, `{:invalid, what}`.
  """
  @spec restore(term()) :: {:ok, map(), facts()} | {:error, term()}
  def restore(snapshot) when is_map(snapshot) do
    with {:ok, snap} <- migrate(snapshot),
         :ok <- check(plain?(snap), :not_plain),
         {:ok, snap} <- shape(snap),
         :ok <- validate(snap) do
      {:ok, build(snap), Map.new(snap.panes, fn {id, p} -> {id, Map.delete(p, :title)} end)}
    end
  end

  def restore(_other), do: {:error, {:invalid, :not_a_map}}

  defp check(true, _what), do: :ok
  defp check(false, what), do: {:error, {:invalid, what}}

  # Structural check; returns the snapshot reduced to the current keys.
  defp shape(%{session: s, focus: %{pane: fp}, ui: ui, panes: panes} = snap)
       when is_map(s) and is_map(ui) and is_map(panes) do
    with :ok <- check(id_or_nil?(fp), :focus),
         {:ok, session} <- shape_session(s),
         :ok <- check(Enum.all?(panes, &pane?/1), :panes),
         :ok <- check(Enum.all?(Map.keys(ui), &is_atom/1), :ui) do
      {:ok, %{snap | session: session}}
    end
  end

  defp shape(_snap), do: {:error, {:invalid, :shape}}

  defp shape_session(
         %{workspaces: wss, active_workspace: aw, next_id: n, size: size, area: area} = s
       )
       when is_list(wss) and is_integer(n) do
    with :ok <- check(id_or_nil?(aw), :active_workspace),
         :ok <- check(size?(size), :size),
         :ok <- check(area?(area), :area),
         :ok <- check(Enum.all?(wss, &ws?/1), :workspaces) do
      {:ok, Map.take(s, [:workspaces, :active_workspace, :next_id, :size, :area])}
    end
  end

  defp shape_session(_s), do: {:error, {:invalid, :session}}

  defp ws?(%{id: id, name: name, active_tab: at, tabs: tabs}) when is_list(tabs),
    do: id?(id) and is_binary(name) and id?(at) and Enum.all?(tabs, &tab?/1)

  defp ws?(_), do: false

  defp tab?(%{id: id, name: name, layout: %{root: root, focus: f, prev_focus: pf}}),
    do: id?(id) and is_binary(name) and tree?(root) and id_or_nil?(f) and id_or_nil?(pf)

  defp tab?(_), do: false

  defp tree?({:pane, id}), do: id?(id)

  defp tree?({:split, dir, r, a, b}) when dir in [:horizontal, :vertical] and is_float(r),
    do: tree?(a) and tree?(b)

  defp tree?(_), do: false

  defp pane?({id, %{title: t, cwd: c, command: cmd, hidden: h}}) do
    id?(id) and (is_nil(t) or is_binary(t)) and (is_nil(c) or is_binary(c)) and
      (is_nil(cmd) or (is_list(cmd) and Enum.all?(cmd, &is_binary/1))) and is_boolean(h)
  end

  defp pane?(_), do: false

  defp area?(%{x: x, y: y, w: w, h: h}),
    do: Enum.all?([x, y], &(is_integer(&1) and &1 >= 0)) and id?(w) and id?(h)

  defp area?(_), do: false

  defp size?(%{cols: c, rows: r}), do: id?(c) and id?(r)
  defp size?(_), do: false

  defp id?(id), do: is_integer(id) and id > 0
  defp id_or_nil?(id), do: is_nil(id) or id?(id)

  defp validate(%{session: s, focus: f, panes: panes}) do
    layout_ids = for ws <- s.workspaces, t <- ws.tabs, id <- ids(t.layout.root), do: id

    trees = for ws <- s.workspaces, t <- ws.tabs, do: t.layout.root

    with :ok <- check(unique?(Enum.map(s.workspaces, & &1.id)), :duplicate_workspace),
         :ok <-
           check(
             Enum.all?(s.workspaces, &unique?(Enum.map(&1.tabs, fn t -> t.id end))),
             :duplicate_tab
           ),
         :ok <- check(Enum.all?(s.workspaces, &(&1.tabs != [])), :workspace_without_tabs),
         :ok <- check(Enum.all?(s.workspaces, &active_tab?/1), :active_tab),
         :ok <- check(Enum.any?(s.workspaces, &(&1.id == s.active_workspace)), :active_workspace),
         :ok <- check(Enum.all?(s.workspaces, &layout_focus?/1), :layout_focus),
         :ok <- check(Enum.all?(trees, &ratios_ok?/1), :ratio),
         :ok <- check(unique?(layout_ids), :pane_in_two_layouts),
         :ok <- check(MapSet.new(layout_ids) == MapSet.new(Map.keys(panes)), :panes_mismatch) do
      check(f.pane == active_focus(s), :focus)
    end
  end

  defp unique?(list), do: length(Enum.uniq(list)) == length(list)

  # Actions keeps focus.pane equal to the active tab's layout focus (`sync/1`)
  defp active_focus(s) do
    ws = Enum.find(s.workspaces, &(&1.id == s.active_workspace))
    Enum.find(ws.tabs, &(&1.id == ws.active_tab)).layout.focus
  end

  # Layout clamps every ratio to [0.1, 0.9]
  defp ratios_ok?({:pane, _}), do: true

  defp ratios_ok?({:split, _, r, a, b}),
    do: r >= 0.1 and r <= 0.9 and ratios_ok?(a) and ratios_ok?(b)

  defp active_tab?(ws), do: Enum.any?(ws.tabs, &(&1.id == ws.active_tab))

  defp layout_focus?(ws) do
    Enum.all?(ws.tabs, fn %{layout: l} -> l.focus in ids(l.root) end)
  end

  defp ids({:pane, id}), do: [id]
  defp ids({:split, _, _, a, b}), do: ids(a) ++ ids(b)

  defp build(%{session: s, focus: f, ui: ui, panes: panes}) do
    max_id = panes |> Map.keys() |> Enum.max(fn -> 0 end)

    session =
      struct(@session,
        workspaces: Enum.map(s.workspaces, &build_ws/1),
        active_workspace: s.active_workspace,
        panes: Map.new(panes, fn {id, p} -> {id, %{title: p.title, layout_gen: 0}} end),
        next_id: max(s.next_id, max_id + 1),
        size: Map.take(s.size, [:cols, :rows]),
        area: s.area
      )

    %{
      session: session,
      focus: struct(@focus, pane: f.pane, modal: []),
      ui: struct(@ui, Map.put(ui, :keybinds, Keybinds.default()))
    }
  end

  defp build_ws(ws) do
    %{
      ws
      | tabs: Enum.map(ws.tabs, fn t -> %{t | layout: build_layout(t.layout)} end)
    }
  end

  defp build_layout(l) do
    prev = if l.prev_focus in ids(l.root), do: l.prev_focus, else: nil
    struct(HerdrServer.Layout, %{l | prev_focus: prev})
  end

  # --- migration ---

  @doc """
  Brings `map` to the current version through `migrations`
  (`%{from_v => {module, fun} | fun_atom}`).
  """
  @spec migrate(map(), migrations()) ::
          {:ok, map()} | {:error, {:newer, integer()} | {:unknown_version, term()}}
  def migrate(map, migrations \\ @migrations)

  def migrate(%{v: @version} = map, _migrations), do: {:ok, map}

  def migrate(%{v: v}, _migrations) when is_integer(v) and v > @version,
    do: {:error, {:newer, v}}

  def migrate(%{v: v} = map, migrations) when is_integer(v) do
    case Map.get(migrations, v) do
      nil -> {:error, {:unknown_version, v}}
      fun when is_atom(fun) -> step(map, v, {__MODULE__, fun}, migrations)
      {m, fun} -> step(map, v, {m, fun}, migrations)
    end
  end

  def migrate(map, _migrations) when is_map(map),
    do: {:error, {:unknown_version, Map.get(map, :v)}}

  @doc false
  # v1 had no session size: App.Session's default (read at runtime, no struct literal)
  @spec v1_to_v2(map()) :: map()
  def v1_to_v2(%{session: %{} = s} = map),
    do: %{map | session: Map.put_new(s, :size, struct(@session).size)}

  def v1_to_v2(map), do: map

  defp step(map, v, {m, fun}, migrations) do
    map |> then(&apply(m, fun, [&1])) |> Map.put(:v, v + 1) |> migrate(migrations)
  end

  # --- plain terms ---

  @doc """
  True when `term` holds only integers, floats, binaries, atoms (booleans and nil
  included), lists, tuples and maps of those: no funs, pids, ports, references or
  improper lists, so it survives `:erlang.binary_to_term(bin, [:safe])` in a later VM.
  """
  @spec plain?(term()) :: boolean()
  def plain?(t) when is_integer(t) or is_float(t) or is_binary(t) or is_atom(t), do: true
  def plain?(t) when is_tuple(t), do: t |> Tuple.to_list() |> plain?()
  def plain?(t) when is_map(t), do: Enum.all?(t, fn {k, v} -> plain?(k) and plain?(v) end)
  def plain?(t) when is_list(t), do: plain_list?(t)
  def plain?(_other), do: false

  defp plain_list?([]), do: true
  defp plain_list?([h | rest]), do: plain?(h) and plain_list?(rest)
  defp plain_list?(_improper_tail), do: false
end
