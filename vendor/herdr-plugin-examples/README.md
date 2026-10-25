# Herdr Plugin Examples

Small example plugins for [Herdr](https://github.com/ogulcancelik/herdr). Each
subdirectory is a standalone plugin with its own `herdr-plugin.toml`.

These are reference examples meant to show the plugin API and authoring patterns.
They are provided as-is and are not actively maintained. Copy what you need into
your own plugin rather than depending on this repo. They require Herdr `0.7.0` or
newer.

## Examples

- `agent-telegram-notify` - JavaScript example that sends a Telegram message
  when an agent reaches a configured status.
- `dev-layout-bootstrap` - Lua example that creates a three-pane development
  layout around the current pane.
- `github-link-preview` - Bash example that opens clicked GitHub issue and PR
  links in a right-side pane with `gh`.
- `rust-release-check` - Rust example that builds during plugin install, then
  checks whether the current Git tree is clean.

Install an example from GitHub:

```sh
herdr plugin install ogulcancelik/herdr-plugin-examples/agent-telegram-notify
herdr plugin install ogulcancelik/herdr-plugin-examples/dev-layout-bootstrap
herdr plugin install ogulcancelik/herdr-plugin-examples/github-link-preview
herdr plugin install ogulcancelik/herdr-plugin-examples/rust-release-check
```

Or clone the examples repo and link a plugin while developing:

```sh
git clone https://github.com/ogulcancelik/herdr-plugin-examples.git
cd herdr-plugin-examples
herdr plugin link ./agent-telegram-notify
herdr plugin link ./dev-layout-bootstrap
herdr plugin link ./github-link-preview
```

`herdr plugin install` runs the Rust example's manifest `[[build]]` command
automatically. For local `plugin link` development, build it yourself first
because linked plugins do not run install-time build commands:

```sh
(cd rust-release-check && cargo build --release)
herdr plugin link ./rust-release-check
```
