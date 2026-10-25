# Dev Layout Bootstrap

Lua Herdr plugin that creates a simple three-pane development layout around the
current pane.

## Behavior

Running the `setup` action:

- renames the current pane to `editor`
- splits right and renames the new pane to `files`
- runs `ls -la` in the `files` pane
- splits the `files` pane downward and renames the new pane to `tasks`
- runs `git status --short` and a small test hint in the `tasks` pane
- runs `nvim .` in the original `editor` pane

The panes are normal Herdr panes after creation. The plugin does not clean them
up or manage their lifecycle.

## Setup

Install locally while developing:

```sh
herdr plugin link .
```

Requires Lua 5.4 or another compatible Lua runtime available as `lua`.

Run it:

```sh
herdr plugin action invoke setup --plugin examples.dev-layout-bootstrap
```

Optional keybind:

```toml
[[keys.command]]
key = "prefix+shift+l"
type = "plugin_action"
command = "examples.dev-layout-bootstrap.setup"
description = "set up dev layout"
```

Or install from the examples repo once published:

```sh
herdr plugin install ogulcancelik/herdr-plugin-examples/dev-layout-bootstrap
```
