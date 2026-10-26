defmodule DynideServer.App.Modal.Keybinds do
  @moduledoc """
  The keybinds modal (`prefix+?`, the global menu; inventory §5 "Keybinds help") with
  herdr-live's editing. State `%{kind: :keybinds, selected, filter: TextField.t(),
  filtering, capture, capturing, after_prefix, error}`.

  The list groups `Keybinds.Catalog` actions under `:text` headings, then the
  `[[keys.command]]` entries (`ui.custom_commands`) under `custom` as
  `{:action, "keys.command[<i>]"}` labelled by their description (else `custom command`);
  each action is an `:item {:action, name}` with one `:keycap` per binding (`ui.keybinds`),
  or a muted `:text` `"unset"`. Custom commands are bound in the config file, not here.
  `/` focuses the filter field (an `:input`; typing narrows by action name, label or
  shortcut; Enter or Down keeps the filter, Esc clears it). j / k / Up / Down move the
  selection, PgUp / PgDn by 10; the list scrolls to keep it visible.

  Capture: Enter (or a click on a row) sets `capture: true`, so `Client.Session` sends
  every key here, the prefix too (subtitle `"press a key for <action> · esc cancels"`).
  The next press rebinds the action through `Keybinds.rebind/3`: after the prefix key it
  is `prefix+<key>`; a ctrl / alt / super chord is a direct bind; any other key is a
  prefix bind. Esc cancels. Success updates `ui.keybinds` (the Store republishes the fast path) and emits
  `{:config_write, ["keys"], kv}` with every action whose bindings changed (the action's
  `[spec]`, `[]` for one that lost its key); a refused spec shows its error.
  """

  @behaviour DynideServer.App.Modal.Kind

  alias DynideScene.Scene.Node
  alias DynideServer.App.CustomCommands
  alias DynideServer.App.Keybinds, as: KB
  alias DynideServer.App.Keybinds.Catalog
  alias DynideServer.App.Modal
  alias DynideServer.App.Modal.TextField
  alias DynideServer.Config.Keys
  alias DynideServer.View.Modal, as: V

  @page 10
  @idle "press / to filter by command or shortcut"
  @footer "search / · scroll j/k/↑↓/pgup/pgdn · rebind enter · close esc"
  @chord [:ctrl, :alt, :meta, :super, :hyper]

  @spec open(map) :: {map, [tuple]}
  def open(app) do
    m = %{
      kind: :keybinds,
      selected: 0,
      filter: TextField.new(""),
      filtering: false,
      capture: false,
      capturing: nil,
      after_prefix: false,
      error: nil
    }

    {Modal.push(app, m), []}
  end

  # --- kind ---

  @impl true
  def ignores_escape?(m), do: m.capture or m.filtering

  @impl true
  def key(%{capture: true} = m, {:key, %{key: k, mods: mods}}, app), do: captured(m, k, mods, app)
  def key(%{filtering: true} = m, ev, app), do: filter_key(m, ev, app)

  def key(m, {:key, %{key: k, mods: []}}, app) do
    m = %{m | error: nil}

    case k do
      "/" -> {:keep, %{m | filtering: true}}
      k when k in [:down, "j"] -> {:keep, move(m, app, 1)}
      k when k in [:up, "k"] -> {:keep, move(m, app, -1)}
      :page_down -> {:keep, move(m, app, @page)}
      :page_up -> {:keep, move(m, app, -@page)}
      :enter -> {:keep, start(m, app)}
      _ -> {:keep, m}
    end
  end

  def key(m, _ev, _app), do: {:keep, m}

  @impl true
  def chrome(m, [:list, {:action, a}], {:click, _}, app) do
    case Enum.find_index(entries(m, app), &(&1.action == a)) do
      nil -> {:keep, m}
      i -> {:keep, start(%{m | selected: i, filtering: false}, app)}
    end
  end

  def chrome(m, [:list | _], {:scroll_down, _}, app), do: {:keep, move(m, app, 1)}
  def chrome(m, [:list | _], {:scroll_up, _}, app), do: {:keep, move(m, app, -1)}
  def chrome(_m, [:actions, :close], {:click, _}, app), do: {:close, app, []}
  def chrome(_m, [:backdrop], {:click, _}, app), do: {:close, app, []}
  def chrome(m, _path, _action, _app), do: {:keep, m}

  @impl true
  def node(m, app, size) do
    rect = V.panel(size, 76, 22)
    rows = max(V.inner_rows(rect) - 5, 0)
    entries = entries(m, app)
    {lines, at} = lines(entries, m.selected)

    filter =
      cond do
        m.filtering -> V.input(m.filter, rect.w)
        m.filter.text != "" -> V.text(:filter, "/ " <> m.filter.text, :muted)
        true -> V.spacer(:filter)
      end

    V.modal(:keybinds, rect, :default, [
      V.title("keybinds"),
      subtitle(m),
      filter,
      V.list(lines, rows, V.window(at, length(lines), rows)),
      V.text(:hint, @footer, :muted),
      V.actions([{:close, "close", :escape, []}])
    ])
  end

  # --- capture ---

  defp start(m, app) do
    case Enum.at(entries(m, app), m.selected) do
      nil -> m
      %{custom: true} -> %{m | error: "custom commands are bound in config.toml"}
      e -> %{m | capture: true, capturing: e.action, after_prefix: false, error: nil}
    end
  end

  defp captured(m, :escape, [], _app), do: {:keep, stop(m, nil)}

  defp captured(m, k, mods, app) do
    mods =
      mods |> Kernel.--([:caps_lock, :num_lock]) |> Enum.map(&if(&1 == :meta, do: :alt, else: &1))

    key = KB.normalize(k, mods |> Enum.uniq() |> Enum.sort())
    kb = app.ui.keybinds

    cond do
      not m.after_prefix and KB.prefix?(kb, key) -> {:keep, %{m | after_prefix: true}}
      :hyper in mods -> {:keep, stop(m, "hyper is not supported")}
      true -> rebind(m, key, app)
    end
  end

  defp rebind(m, {k, mods}, app) do
    prefix = m.after_prefix or not Enum.any?(mods, &(&1 in @chord))
    spec = Keys.format(%{prefix: prefix, key: k, mods: mods})

    case KB.rebind(app.ui.keybinds, m.capturing, spec) do
      {:ok, kb} ->
        # every changed action, so a displaced one is written as [] too
        old = KB.to_config(app.ui.keybinds)
        kv = kb |> KB.to_config() |> Map.reject(fn {a, v} -> old[a] == v end)
        {:keep, stop(m, nil), put_in(app.ui.keybinds, kb), [{:config_write, ["keys"], kv}]}

      {:error, msg} ->
        {:keep, stop(m, msg)}
    end
  end

  defp stop(m, error),
    do: %{m | capture: false, capturing: nil, after_prefix: false, error: error}

  # --- filter ---

  defp filter_key(m, {:key, %{key: :escape, mods: []}}, _app),
    do: {:keep, %{m | filtering: false, filter: TextField.clear(m.filter), selected: 0}}

  defp filter_key(m, {:key, %{key: k, mods: []}}, _app) when k in [:enter, :down],
    do: {:keep, %{m | filtering: false}}

  defp filter_key(m, ev, _app) do
    case TextField.key(m.filter, ev) do
      {:ok, f} -> {:keep, %{m | filter: f, selected: 0}}
      :ignore -> {:keep, m}
    end
  end

  # --- rows ---

  defp entries(m, app) do
    q = String.downcase(String.trim(m.filter.text))
    kb = app.ui.keybinds
    cfg = KB.to_config(kb)

    catalog =
      for e <- Catalog.entries(),
          do: %{
            action: e.action,
            group: e.group,
            label: Catalog.label(e.action),
            specs: cfg[e.action],
            custom: false
          }

    custom =
      for {c, i} <- Enum.with_index(app.ui.custom_commands) do
        %{
          action: "keys.command[#{i}]",
          group: "custom",
          label: c.description || "custom command",
          specs: KB.specs(kb, {CustomCommands, :run, [i]}),
          custom: true
        }
      end

    Enum.filter(catalog ++ custom, fn e ->
      q == "" or
        Enum.any?([e.action, String.downcase(e.label) | e.specs], &String.contains?(&1, q))
    end)
  end

  defp move(m, app, d) do
    n = length(entries(m, app))
    %{m | selected: (m.selected + d) |> min(n - 1) |> max(0)}
  end

  # headings and items, plus the line index of the selected item
  defp lines([], _selected), do: {[V.text(:empty, "no matching keybinds", :muted)], 0}

  defp lines(entries, selected) do
    {lines, at, _, _} =
      entries
      |> Enum.with_index()
      |> Enum.reduce({[], 0, nil, 0}, fn {e, i}, {acc, at, group, n} ->
        {acc, n} =
          if e.group == group,
            do: {acc, n},
            else: {[V.text({:group, e.group}, e.group, :accent) | acc], n + 1}

        at = if i == selected, do: n, else: at
        {[item(e, i == selected) | acc], at, e.group, n + 1}
      end)

    {Enum.reverse(lines), at}
  end

  defp item(e, selected) do
    caps =
      e.specs
      |> Enum.with_index()
      |> Enum.map(fn {s, i} ->
        {:ok, parsed} = Keys.parse(s)
        V.keycap(parsed, {:key, i})
      end)

    %Node{
      role: :item,
      id: {:action, e.action},
      text: e.label,
      props: %{selected: selected},
      children: if(caps == [], do: [V.text(:unset, "unset", :muted)], else: caps)
    }
  end

  defp subtitle(%{capture: true, capturing: a}),
    do: V.text(:subtitle, "press a key for #{a} · esc cancels", :accent)

  defp subtitle(%{error: e}) when is_binary(e), do: V.text(:subtitle, e, :error)
  defp subtitle(_m), do: V.text(:subtitle, @idle, :muted)
end
