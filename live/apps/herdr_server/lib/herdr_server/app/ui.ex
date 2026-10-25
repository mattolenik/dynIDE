defmodule HerdrServer.App.Ui do
  @moduledoc """
  UI configuration carried in app state, with herdr's defaults: sidebar geometry
  (`width` clamped to `min..max` while expanded, `split` the spaces/agents ratio, the
  lists' scroll `spaces_offset` / `agents_offset`), tab bar
  position, theme names, agent state indicators, confirmations, toast and sound delivery, `pane_borders` (`Layout.borders/3`).
  Older apps get the new keys from `App.Upgrade.app/1`.
  """

  defstruct [
    :keybinds,
    status: %{show_hints: true},
    theme: %{
      name: "catppuccin",
      auto_switch: false,
      light: "catppuccin-latte",
      dark: "catppuccin"
    },
    sidebar: %{
      visible: true,
      collapsed: false,
      width: 26,
      min: 18,
      max: 36,
      split: 0.5,
      spaces_offset: 0,
      agents_offset: 0
    },
    tab_bar: %{position: :top},
    indicators: :dots,
    confirm_close: true,
    onboarding: false,
    toast: %{delivery: :herdr, delay_ms: 1000},
    sound: %{enabled: true, command: nil},
    prompt_new_tab_name: true,
    pane_borders: :auto,
    window_title: "{hostname}: {workspace}"
  ]

  @type t :: %__MODULE__{
          keybinds: HerdrServer.App.Keybinds.t(),
          status: %{show_hints: boolean()},
          theme: %{name: binary(), auto_switch: boolean(), light: binary(), dark: binary()},
          sidebar: %{
            visible: boolean(),
            collapsed: boolean(),
            width: pos_integer(),
            min: pos_integer(),
            max: pos_integer(),
            split: float(),
            spaces_offset: non_neg_integer(),
            agents_offset: non_neg_integer()
          },
          tab_bar: %{position: :top | :bottom},
          indicators: :dots | :symbols,
          confirm_close: boolean(),
          onboarding: boolean(),
          toast: %{delivery: atom(), delay_ms: non_neg_integer()},
          sound: %{enabled: boolean(), command: binary() | nil},
          prompt_new_tab_name: boolean(),
          pane_borders: :auto | :always | :off,
          window_title: binary()
        }
end
