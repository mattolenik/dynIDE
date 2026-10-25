# M14 manual checklist: plugins

Run this in a real terminal against a daily-driver `bin/herdr-live` (`just live-run`). Commands use `$HERDR_LIVE_BIN` from a pane. It takes about 10 minutes. Real `gh` and `nvim` are used if they are installed.

## A. Install and list

1. Run `$HERDR_LIVE_BIN plugin install <repo>/vendor/herdr-plugin-examples/dev-layout-bootstrap`, without `--yes`.
   - The preview lists the `setup` action and `lua setup.lua`.
   - The exit status is 1, and the output asks you to re-run with `--yes`.
2. Run the same command with `--yes`, then the same for `github-link-preview`.
   - `plugin list` shows both plugins, enabled, with no `error`.
3. Run `plugin config-dir examples.github-link-preview`.
   - It prints a path under `~/.config/herdr-live/plugins/config/`.
   - Nothing is written under herdr's own `~/.config/herdr`.

## B. Actions, menus, keybinds

1. In a fresh tab, run `plugin action invoke examples.dev-layout-bootstrap.setup`.
   - The pane becomes `editor`, with `files` to the right and `tasks` below it.
   - `nvim .` opens in the editor.
   - `plugin log list` shows the run as `succeeded`.
2. Right-click a pane, then the global menu.
   - Plugin actions appear only if their manifest `contexts` match. The examples declare none, so they appear in the global menu.
   - Selecting one runs it.
3. Add a keybind to `~/.config/herdr-live/config.toml` and reload with `prefix R`:
   ```toml
   [[keys.command]]
   key = "prefix+l"
   type = "plugin_action"
   command = "examples.dev-layout-bootstrap.setup"
   ```
   - `prefix l` runs the layout again.
   - A `type = "shell"` entry gives a "not supported yet" warning (M17 owns it).

## C. Link handlers

1. In a pane, print an OSC 8 link:
   ```sh
   printf '\e]8;;https://github.com/ogulcancelik/herdr/issues/1\e\\issue\e]8;;\e\\\n'
   ```
   - Ctrl+click it. A `GitHub preview` split opens on the right and shows the issue through `gh`, or "gh is required".
   - The browser does not open.
2. Ctrl+click a plain `https://example.com` link. It opens in the browser (no handler matches).
3. Ctrl+Alt+click the GitHub link (Ctrl+Option on macOS). It is handled again.
   - In `plugin log list`, the run's context has `click_modifiers` `["alt","ctrl"]`.
4. Run `plugin disable examples.github-link-preview`, then ctrl+click the GitHub link.
   - It opens in the browser.
   - Re-enable the plugin afterwards.

## D. Failure isolation

1. Break the manifest: edit the installed copy of dev-layout-bootstrap's `herdr-plugin.toml` (path from `plugin list`, `plugin_root`) and delete its `version` line.
   - `plugin list` shows that plugin with an `error`.
   - One toast and one log warning mention it.
   - github-link-preview still works.
2. Restore the line. The next invoke works without restarting anything.
3. Run `herdr-live kernel-restart` with a plugin pane open.
   - The pane survives.
   - Startup hooks run again (none in the examples). This is herdr's documented behaviour.

## E. Cleanup

1. Run `plugin uninstall examples.dev-layout-bootstrap` and `plugin remove examples.github-link-preview`.
   - `plugin list` is empty.
   - The config and state dirs remain, as in herdr.

Record pass or fail per step, with notes, in the dogfood log.
