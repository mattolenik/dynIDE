# Agent Telegram Notify

JavaScript Herdr plugin that sends a Telegram message when an agent changes to a
configured status.

## Setup

Install from GitHub:

```sh
herdr plugin install ogulcancelik/herdr-plugin-examples/agent-telegram-notify
CONFIG_DIR="$(herdr plugin config-dir examples.agent-telegram-notify)"
cp .env.example "$CONFIG_DIR/.env"
```

Edit the copied `.env` in the printed config directory:

```sh
TELEGRAM_BOT_TOKEN=123456:abc...
TELEGRAM_CHAT_ID=123456789
```

`herdr plugin config-dir` is available in the Herdr release that includes
stable plugin config directories. Until then, use a current Herdr build from
`master`.

Or clone and link locally while developing:

```sh
git clone https://github.com/ogulcancelik/herdr-plugin-examples.git
cd herdr-plugin-examples/agent-telegram-notify
herdr plugin link .
CONFIG_DIR="$(herdr plugin config-dir examples.agent-telegram-notify)"
cp .env.example "$CONFIG_DIR/.env"
```

Local `.env` in this directory still works as a development fallback:

```sh
cp .env.example .env
```

## Toggle with a keybind

The plugin stays installed and enabled in Herdr. The toggle action writes a local
state file that the event hook checks before sending messages.

Add this keybind to Herdr:

```toml
[[keys.command]]
key = "prefix+shift+t"
type = "plugin_action"
command = "examples.agent-telegram-notify.toggle"
description = "toggle Telegram notifications"
```

Manual controls:

```sh
herdr plugin action invoke toggle --plugin examples.agent-telegram-notify
herdr plugin action invoke enable --plugin examples.agent-telegram-notify
herdr plugin action invoke disable --plugin examples.agent-telegram-notify
```

When enabled, the toggle action sets the host terminal title to `TG on` as
a small visible mode indicator. Set `HERDR_TELEGRAM_SET_TITLE=0` in `.env` to
disable title changes.

## Notes

- Requires Node.js 18 or newer.
- Uses no npm packages.
- Reads Herdr event context from `HERDR_PLUGIN_CONTEXT_JSON`.
- Reads installed-plugin config from `HERDR_PLUGIN_CONFIG_DIR/.env`.
- Sends notifications when an agent reaches `done`.
- Local `./.env` is a development fallback and should not be committed.
