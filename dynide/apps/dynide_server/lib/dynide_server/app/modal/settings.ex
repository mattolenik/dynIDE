defmodule DynideServer.App.Modal.Settings do
  @moduledoc """
  The settings modal (`%{kind: :settings, section, cursor, original}`, inventory §6;
  `prefix+s` and the global menu). Sections `theme`, `indicators`, `sound`, `toasts`
  (integrations wait for M11), each a choice list with the current value marked.

  Keys: Tab / Right / `l` and shift+Tab / Left / `h` switch section (wrapping; the cursor
  starts on the section's current value), Up / Down / `k` / `j` move the cursor, Enter
  or Space applies. Clicks: a section tab, a choice (selects it), `apply`, `close`.

  The theme cursor live-previews by setting `ui.theme.name` (auto switch off while
  previewing); Esc, `close`, a backdrop click or leaving the section restore `original`.
  Applying a theme writes `[theme] name` with `auto_switch = false` and closes. The other
  sections stay open after applying and write `[ui] status_indicators` (`"dots"` /
  `"symbols"`), `[ui.sound] enabled`, `[ui.toast] delivery` (`"off" | "herdr" |
  "terminal" | "system"`), as `{:config_write, table, kv}` effects.
  """

  @behaviour DynideServer.App.Modal.Kind

  alias DynideServer.App.Modal
  alias DynideServer.View.Modal, as: V

  @themes ~w(catppuccin catppuccin-latte terminal tokyo-night tokyo-night-day dracula nord) ++
            ~w(gruvbox gruvbox-light one-dark one-light solarized solarized-light kanagawa) ++
            ~w(kanagawa-lotus rose-pine rose-pine-dawn vesper)

  @sections [theme: "theme", indicators: "indicators", sound: "sound", toasts: "toasts"]
  @order Keyword.keys(@sections)

  @text %{
    indicators:
      {"agent status indicators", "choose color dots or distinct symbols for each state"},
    sound: {"sound alerts", "play sounds when agents change state in background"},
    toasts: {"notification popups", "choose where background popup notifications should appear"}
  }

  @choices %{
    indicators: [dots: "color dots", symbols: "distinct symbols"],
    sound: [{true, "on"}, {false, "off"}],
    toasts: [off: "off", herdr: "inside dynIDE", terminal: "via terminal", system: "via system"]
  }

  @doc "herdr's 18 built-in theme names (`config/theme.rs`)."
  @spec themes() :: [binary]
  def themes, do: @themes

  @spec open(map) :: {map, [tuple]}
  def open(app) do
    m = %{kind: :settings, section: :theme, cursor: 0, original: app.ui.theme}
    {Modal.push(app, %{m | cursor: current_index(m, app)}), []}
  end

  # --- kind ---

  @impl true
  def ignores_escape?(_m), do: true

  @impl true
  def key(m, {:key, %{key: :tab, mods: [:shift]}}, app), do: section(m, app, -1)

  def key(m, {:key, %{key: k, mods: []}}, app) do
    cond do
      k in [:tab, :right, "l"] -> section(m, app, 1)
      k in [:left, "h"] -> section(m, app, -1)
      k in [:down, "j"] -> select(m, app, m.cursor + 1)
      k in [:up, "k"] -> select(m, app, m.cursor - 1)
      k in [:enter, " "] -> apply_choice(m, app)
      k == :escape -> {:close, restore(m, app), []}
      true -> {:keep, m}
    end
  end

  def key(m, _ev, _app), do: {:keep, m}

  @impl true
  def chrome(m, [:sections, {:section, s}], {:click, _}, app) when s in @order,
    do: section(m, app, index(@order, s) - index(@order, m.section))

  def chrome(m, [:list, {:choice, i}], {:click, _}, app), do: select(m, app, i)
  def chrome(m, [:list | _], {:scroll_down, _}, app), do: select(m, app, m.cursor + 1)
  def chrome(m, [:list | _], {:scroll_up, _}, app), do: select(m, app, m.cursor - 1)
  def chrome(m, [:actions, :apply], {:click, _}, app), do: apply_choice(m, app)
  def chrome(m, [:actions, :close], {:click, _}, app), do: {:close, restore(m, app), []}
  def chrome(m, [:backdrop], {:click, _}, app), do: {:close, restore(m, app), []}
  def chrome(m, _path, _action, _app), do: {:keep, m}

  @impl true
  def node(m, app, size) do
    rect = V.panel(size, 76, 22)
    head = [V.title("settings"), V.sections(m.section, @sections), V.spacer(:gap)]

    head =
      case Map.get(@text, m.section) do
        {heading, desc} ->
          head ++
            [V.text(:heading, heading, :strong), V.text(:description, desc, :muted)] ++
            [V.spacer(:gap2)]

        _ ->
          head
      end

    # title, the tabs row and its rule, the gap; the hint and the actions after the list
    used = Enum.sum(Enum.map(head, &rows/1))
    rows = max(V.inner_rows(rect) - used - 2, 0)
    items = items(m, app)

    V.modal(
      :settings,
      rect,
      :default,
      head ++
        [
          V.list(items, rows, V.window(m.cursor, length(items), rows)),
          V.text(:hint, "↑↓ select  tab section", :muted),
          V.actions([{:apply, "apply", :enter, []}, {:close, "close", :escape, []}])
        ]
    )
  end

  defp rows(%{role: :tabs}), do: 2
  defp rows(%{role: :spacer, props: %{rows: n}}), do: n
  defp rows(_), do: 1

  defp items(m, app) do
    current = current_value(m, app)

    m.section
    |> values()
    |> Enum.with_index()
    |> Enum.map(fn {{v, label}, i} ->
      extra = if m.section == :indicators, do: %{indicators: v}, else: %{}
      V.choice({:choice, i}, label, i == m.cursor, v == current, extra)
    end)
  end

  # --- helpers ---

  defp values(:theme), do: Enum.map(@themes, &{&1, &1})
  defp values(section), do: Map.fetch!(@choices, section)

  defp current_value(%{section: :theme, original: o}, _app), do: o.name
  defp current_value(%{section: :indicators}, app), do: app.ui.indicators
  defp current_value(%{section: :sound}, app), do: app.ui.sound.enabled
  defp current_value(%{section: :toasts}, app), do: app.ui.toast.delivery

  defp current_index(m, app) do
    v = current_value(m, app)
    Enum.find_index(values(m.section), &(elem(&1, 0) == v)) || 0
  end

  defp section(m, app, delta) do
    n = length(@order)
    s = Enum.at(@order, rem(index(@order, m.section) + delta + n, n))
    app = restore(m, app)
    m = %{m | section: s}
    {:keep, %{m | cursor: current_index(m, app)}, app, []}
  end

  defp select(m, app, i) do
    i = i |> max(0) |> min(length(values(m.section)) - 1)
    m = %{m | cursor: i}

    if m.section == :theme,
      do: {:keep, m, put_theme(app, m.original, Enum.at(@themes, i)), []},
      else: {:keep, m, app, []}
  end

  defp apply_choice(%{section: :theme} = m, app) do
    name = Enum.at(@themes, m.cursor)

    {:close, put_theme(app, m.original, name),
     [{:config_write, ["theme"], %{"name" => name, "auto_switch" => false}}]}
  end

  defp apply_choice(m, app) do
    {v, _} = Enum.at(values(m.section), m.cursor)
    {app, write} = set(m.section, v, app)
    {:keep, m, app, [write]}
  end

  defp set(:indicators, v, app),
    do:
      {put_in(app.ui.indicators, v),
       {:config_write, ["ui"], %{"status_indicators" => Atom.to_string(v)}}}

  defp set(:sound, v, app),
    do: {put_in(app.ui.sound.enabled, v), {:config_write, ["ui", "sound"], %{"enabled" => v}}}

  defp set(:toasts, v, app),
    do:
      {put_in(app.ui.toast.delivery, v),
       {:config_write, ["ui", "toast"], %{"delivery" => Atom.to_string(v)}}}

  defp put_theme(app, original, name),
    do: put_in(app.ui.theme, %{original | name: name, auto_switch: false})

  defp restore(m, app), do: put_in(app.ui.theme, m.original)

  defp index(list, x), do: Enum.find_index(list, &(&1 == x))
end
