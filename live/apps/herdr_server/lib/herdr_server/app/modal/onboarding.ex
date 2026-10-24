defmodule HerdrServer.App.Modal.Onboarding do
  @moduledoc """
  The first-run welcome (`%{kind: :onboarding}`, inventory §5), opened by
  `Actions.init` when `ui.onboarding` is set (`at_start/1`). herdr's lines, with
  `herdr-live` as the title; the prefix line shows `ui.keybinds.prefix` and `?` as
  keycaps. Panel `max(hint + 5, 64)` x 16, one button `continue` (Enter).

  Enter, Right, `l` or the `continue` button close it, set `ui.onboarding: false` and
  emit `{:config_write, [], %{"onboarding" => false}}`. Esc, other keys and backdrop
  clicks do nothing (`ignores_escape?`).
  """

  @behaviour HerdrServer.App.Modal.Kind

  alias HerdrServer.App.Modal
  alias HerdrServer.View.Modal, as: V

  @suffix " enters prefix mode · "
  @help " shows keybinds and settings"

  @spec at_start(map) :: map
  def at_start(%{ui: %{onboarding: true}} = app), do: Modal.push(app, %{kind: :onboarding})
  def at_start(app), do: app

  # --- kind ---

  @impl true
  def ignores_escape?(_m), do: true

  @impl true
  def key(_m, {:key, %{key: k, mods: []}}, app) when k in [:enter, :right, "l"], do: done(app)
  def key(m, _ev, _app), do: {:keep, m}

  @impl true
  def chrome(_m, [:actions, :continue], {:click, _}, app), do: done(app)
  def chrome(m, _path, _action, _app), do: {:keep, m}

  @impl true
  def node(_m, app, size) do
    prefix =
      case app.ui.keybinds.prefix do
        [{k, mods} | _] -> V.keycap(%{prefix: false, key: k, mods: mods}, :prefix)
        [] -> V.text(:prefix, "", :accent)
      end

    help = V.keycap(%{prefix: false, key: "?", mods: []}, :help)
    keys = [prefix, V.text(:suffix, @suffix), help, V.text(:help_text, @help)]
    hint = 2 + Enum.sum(Enum.map(keys, &String.length(&1.text)))
    rect = V.panel(size, max(hint + 5, 64), 16)

    body = [
      V.title("herdr-live"),
      V.text(:subtitle, "terminal workspace manager for coding agents", :muted),
      V.spacer(:gap),
      V.line(0, "this is a mouse-first terminal."),
      V.line(1, "click the sidebar to switch workspaces, drag pane"),
      V.line(2, "borders to resize, right-click for context menus."),
      V.spacer(:gap2),
      %HerdrScene.Scene.Node{role: :group, id: {:line, 3}, children: keys},
      V.line(4, "next: install optional agent integrations for more reliable state")
    ]

    # the button on the last inner row
    fill = V.spacer(:fill, max(V.inner_rows(rect) - 1 - 9, 0))

    V.modal(
      :onboarding,
      rect,
      :default,
      body ++ [fill, V.actions([{:continue, "continue", :enter, []}])]
    )
  end

  defp done(app),
    do:
      {:close, put_in(app.ui.onboarding, false), [{:config_write, [], %{"onboarding" => false}}]}
end
