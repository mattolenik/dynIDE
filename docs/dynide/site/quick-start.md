# Quick start

```sh
dynide              # start the instance in this terminal
dynide attach       # join it from another terminal
```

The prefix key is `ctrl+b`. Defaults (see the in-app keybind help for the full list):

| keys | action |
|---|---|
| `ctrl+b v` / `ctrl+b -` | split vertically / horizontally |
| `ctrl+b z` | zoom the focused pane |
| `ctrl+b g` / `ctrl+b w` | go-to navigator / workspace navigate mode |
| `ctrl+b q` | quit the client (detaches only that client when attached) |
| `ctrl+b [` / `ctrl+b ?` | copy mode / keybind help |

The UI is mouse-first: click tabs, workspaces and menus; drag to reorder; select text and
it is copied. Configuration is `${XDG_CONFIG_HOME:-~/.config}/dynide/config.toml` (`DYNIDE_CONFIG`); `dynide --default-config` prints the
commented defaults.

## From another shell or a pane

```sh
dynide status            # broker, primary and standby, last handoff
dynide ping
dynide pane list
dynide kernel-restart    # restart the kernel under live children
dynide help              # every verb
```

Every verb talks to the socket API: [api.md](../api.md).

## State

Layout, focus, UI prefs, pane cwds and the last 1000 rows of scrollback are saved to
`${XDG_STATE_HOME:-$HOME/.local/state}/dynide/session.<name>.etf` and restored at the
next start. A restored pane starts `$SHELL` in its old cwd; running programs do not
survive a full stop, only a kernel restart or crash handoff. `DYNIDE_SESSION` picks
the name, `DYNIDE_PERSIST=0` turns saving off. Logs go to
`${XDG_STATE_HOME:-$HOME/.local/state}/dynide/dynide.log` (`DYNIDE_LOG`).
