# Release notes: 0.1.0

First release. Terminal-only: the GUI client (M15) is not included. Targets macOS arm64
and Linux aarch64 (Linux was run in an aarch64 VM on a Mac; x86_64 and bare-metal Linux
were not). The release is a production build with hot reload off.

## What is in 0.1.0

- M0 skeleton: umbrella, launcher, CI, vendored libghostty-vt.
- M1 kernel: PTY and ghostty VT in Rust, packed dirty rows, structured events.
- M2 terminal kernel: host tty (raw mode, kitty keyboard) and the ANSI blitter.
- M3 server and terminal client: sessions, workspaces, tabs, pane tree, scene/row split.
- M4 reload and rollback: live code reload with automatic rollback (source checkouts only).
- M5 kernel restart: handoff of live PTYs to a new kernel and VM, including after a crash.
- M6 gate: slice-1 performance gate passed on macOS and Linux ([ADR 0001](../adr/0001-slice-1-gate.md)).
- M7 self-hosting: edit herdr-live from inside itself (source checkouts only).
- M8 persistence: layout, prefs, cwds and scrollback survive a full restart.
- M9 terminal fidelity: scrollback, selection, copy mode and search, links, paste, reflow.
- M10 kitty graphics: images and placements, equal to herdr in the manual comparison.
- M11 detection: agent detection and agent facts. <!-- m18: confirm M11 has merged before release; if not, delete this line -->
- M12 API and CLI: socket API, `herdr-live <verb>` CLI, event streams.
- M13 chrome: sidebar, tabs, menus, modals, toasts, themes, `config.toml`, keybind UI.
- M14 plugins: herdr's external-process plugin model.
- M16 remote attach: more clients, local or over ssh, with reconnect and kernel-restart survival.
- M17 long tail: zoom, worktrees, navigator, custom commands and popups, drag-reorder,
  notifications and sounds, shell completion.
- M18 release: tarball build, installer, `herdr-live update`, this documentation.

## Known limitations

Assembled from every "Known gaps" section; internal test and code-hygiene items are
left in the results files. Each entry names its source.

### Distribution

- No hot reload or remote shell in the release; live editing needs a source checkout.
  ([m18 rulings R1, R3](../results/m18.md))
- An update does not replace the running broker binary; broker-side fixes need a full
  stop and start. ([m18 ruling R4](../results/m18.md))
- No update notifications, in-app release notes or announcements; use
  `herdr-live update --check`. ([m18 ruling R8](../results/m18.md))
- `attach` runs a client VM and, in a source checkout, needs a compiled tree on the
  client machine; the release has no separate client package.
  ([m16](../results/m16.md), note for M18)
- Linux was only run on aarch64 in a VM; the gate's Linux typing max during a flood is
  69-622 ms (p95 11-12 ms). ([m6-gate](../results/m6-gate.md))
- A demoted Linux flood reader stays at nice 10 without `CAP_SYS_NICE`.
  ([m6-gate](../results/m6-gate.md))

### Sessions and handoff

- A full quit restores layout, cwd and scrollback (last 1000 rows as VT text) but not
  running programs; restore starts `$SHELL`. Kitty images are not persisted.
  ([m8](../results/m8.md), [m10](../results/m10.md))
- Kitty images are lost across `kernel-restart` until the child sends them again.
  ([m10](../results/m10.md), deferred in [m17-inventory](../results/m17-inventory.md))
- Exit status of children adopted by a new VM is `:unknown`.
  ([m5](../results/m5.md))
- A cold handoff with no ready standby takes about 1.0-1.1 s under load; one outlier of
  1085 ms with a standby was not explained. ([m5](../results/m5.md))
- A key that races the freeze can be acked and lost; output the target read before a
  failed handoff can be missing from the old VM's screen. ([m5](../results/m5.md))
- A hard kill during a Mix compile can leave a mixed beam set that a promoted standby
  loads. ([m6-gate](../results/m6-gate.md))
- Events during a Store restart are lost; the stream resumes from a fresh snapshot.
  ([m12](../results/m12.md))
- Remote: a hidden-tab pane observed remotely is stale until its tab is shown; one
  keystroke can apply twice after a server crash (at-least-once); presentation state is
  lost across a handoff and the client gets a full scene. ([m16](../results/m16.md))
- A remote client ignores `[ui.sound] command`; set `HERDR_LIVE_SOUND_COMMAND`.
  ([m16](../results/m16.md))
- The ssh relay finds the server in ssh's non-interactive environment; custom socket
  paths or an off-`PATH` install need `HERDR_LIVE_REMOTE_BIN`. ([m16](../results/m16.md))
- Typing under a 15-pane flood has p50 about 11 ms (idle 0.45 ms). ([m16](../results/m16.md))

### Terminal fidelity

- Copy-mode search for a miss over 20 000 rows takes about 1.1 s and stalls that
  client's input meanwhile; a kernel-side search was deferred. ([m9](../results/m9.md),
  [m17-inventory](../results/m17-inventory.md))
- Copy mode: a focus move ends it; search matches are not cleared by new output; absolute
  rows drift at full scrollback; mouse-wheel scrolling is not reflected in its position.
  ([m9](../results/m9.md))
- A queued paste cannot be cancelled; Ctrl-C waits behind it. ([m9](../results/m9.md))
- Not ported: herdr's macOS Option-as-Alt non-ASCII table and legacy shell-key and
  super-chord handling for panes without a keyboard protocol. ([m1](../results/m1.md),
  [m9](../results/m9.md))
- Focus reports always send Gained to the newly focused pane. ([m9](../results/m9.md))
- OSC 52 writes over 192 KiB are refused; a host that ignores DSR 5n delays the colour
  query by 5 s. ([m9](../results/m9.md))
- Kitty graphics: an implicit placement can collide with an explicit one of the same id;
  one cell-size geometry per pane (a second client with other cell pixels may be off by
  a fraction of a cell); no size cap or per-scene byte budget; the shared
  `/tmp/herdr-live-kitty-<uid>/` upload directory is never cleaned.
  ([m10](../results/m10.md), [m17-inventory](../results/m17-inventory.md))
- Scroll step and copy-on-select are fixed at 3 lines and on. ([m9](../results/m9.md))

### Chrome and UX

- Two close semantics: chrome closing the last tab or pane removes the workspace (after a
  confirm); the API's `tab.close` and `pane.close` keep the workspace with a fresh tab.
  ([m13](../results/m13.md))
- Not built: mobile layout (width up to 64), the settings `integrations` section, the
  agents sort label, rebinding indexed `switch_tab`. ([m13](../results/m13.md))
- Auto light/dark depends on the host answering colour queries (or `COLORFGBG`).
  ([m9](../results/m9.md), [m13](../results/m13.md))
- Workspace and tab ids are reused after a close (highest plus one); pane ids are not.
  ([m12](../results/m12.md))
- Keys that the client resolves locally (prefix, direct binds) do not reach a modal.
  ([m13](../results/m13.md))
- Hover is not cleared on pointer leave or focus-out. ([m17](../results/m17.md))
- Tab bar: with `hide_single` a Store-restart reconcile that adds or drops a tab does not
  reframe until the next tab, workspace or resize action. ([m17](../results/m17.md))
- A reload of a pre-M13 state into a running VM rolls back; applies only to dev
  instances upgraded in place. ([m13](../results/m13.md))

### API, CLI and plugins

- The CLI prints herdr's `{"id","result"}` envelope, but `plugin list`, `plugin install`
  and `plugin uninstall` print it where herdr prints human text (herdr's `--json` form),
  and request ids are `cli:<method>`, not herdr's per-verb ids. ([m18](../results/m18.md))
- `plugin update` is not ported; also not ported: per-plugin checkout locks across VMs,
  `pane.link.resolve`, stale-target checks on `pane.link.activate`, cleanup of old
  managed installs. ([m14](../results/m14.md))
- Plugin commands have no default timeout (as in herdr); 32 hung commands block plugin
  runs. `pane.exited` and
  `pane.moved` hooks never fire. ([m14](../results/m14.md))
- `pane.read` has no `recent-unwrapped`, `detection` or ANSI source; `pane.process_info`
  has no foreground process list. ([m12](../results/m12.md))
- Each connection has a 1 MiB receive buffer and at most 16 pipelined requests during a
  wait. ([m12](../results/m12.md))
- Popups with `identity: false` still inherit pane-identity variables the VM already had
  (the kernel spawn can only set variables). ([m17](../results/m17.md))
- `pane.swap` lacks herdr's `source_pane_id`/`target_pane_id` form; a paneless
  `notification.show` raises no `notification.shown` event;
  `resume_argv` reports are refused until agent detection claims the pane.
  ([m17](../results/m17.md))
- The CLI caches the Elixir ebin path and does not notice an Elixir upgrade while the old
  directory exists (source checkout). ([m12](../results/m12.md))

### Agents

- Agent states and labels depend on M11 detection; without it badges show `unknown` and
  agent notifications and dots do not fire. ([m13](../results/m13.md),
  [m17](../results/m17.md)) <!-- m18: drop or restate once M11's merge is known -->

### Reload (source checkouts)

- A blocked source still loads in a new VM after a handoff; other `Server.reload` entry
  points bypass the test gate; reload status does not carry across a handoff.
  ([m7](../results/m7.md))
- `HerdrReload.Telemetry.event/2` is outside the guard; a bad edit to it can break the
  Store restart or the guard failure path. ([m7](../results/m7.md),
  [editing-live.md](../editing-live.md))
- After a rollback only a content change reloads the source; re-saving it unchanged does
  nothing. A hang in `Actions.apply` or the Store has no budget. ([m4](../results/m4.md))
- Two instances writing the same log produce false `broker_died` losses in
  `log_summary.py`. ([m7](../results/m7.md))
- The reload watcher needs `inotify-tools` on Linux. ([m4](../results/m4.md))

## Fixed since their results file

Dropped from the list above: the demo-mode flake (product bug, fixed after M7, commits
`c5118e97`, `d5abcdf4`; [m7](../results/m7.md)); a raw tty after `kill -9` of the broker
and operator-kill counting as a session loss (M17 task 1, [m17](../results/m17.md)); rejected
beams accumulating (M17 task 2 prunes to 20); the `conn.ex` compile warning (M17 task 4);
no zoom, pane borders, hover, navigator, worktrees, tab-bar options, drag-reorder,
`--default-config`, completion, `split --cwd/--env`, system toasts (M17 inventory);
plugin popups (M17 task 23); a module removed by rollback keeping its beam (M4 phase 2).

## Pending in this release

Filled by the M18 owner at the end: open items of M18 itself (CLI envelope, `plugin update`,
kernel search, image carry, update-manifest and signing status, perf/stability results).

- (to be filled)
