# Quick start

```sh
herdr-live              # start (or attach to) the instance in this terminal
```

The prefix key is `ctrl+b`. Defaults (see the in-app keybind help for the full list):

| keys | action |
|---|---|
| `ctrl+b v` / `ctrl+b -` | split vertically / horizontally |
| `ctrl+b z` | zoom the focused pane |
| `ctrl+b g` / `ctrl+b w` | go-to navigator / workspace navigate mode |
| `ctrl+b q` | quit the client (detaches only that client when attached) |

The UI is mouse-first: click tabs, workspaces and menus; drag to reorder; select text and
it is copied. Configuration is a TOML file; `herdr-live --default-config` prints the
commented defaults.

## From another shell or a pane

```sh
herdr-live status            # broker, primary and standby, last handoff
herdr-live ping
herdr-live pane list
herdr-live kernel-restart    # restart the kernel under live children
herdr-live help              # every verb
```

Every verb talks to the socket API: [api.md](../api.md).

## State

Layout, focus, UI prefs, pane cwds and the last 1000 rows of scrollback are saved to
`${XDG_STATE_HOME:-$HOME/.local/state}/herdr-live/session.<name>.etf` and restored at the
next start. A restored pane starts `$SHELL` in its old cwd; running programs do not
survive a full stop, only a kernel restart or crash handoff. `HERDR_LIVE_SESSION` picks
the name, `HERDR_LIVE_PERSIST=0` turns saving off. Logs go to
`${XDG_STATE_HOME:-$HOME/.local/state}/herdr-live/herdr-live.log` (`HERDR_LIVE_LOG`).
