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
- M7 self-hosting: edit dynIDE from inside itself (source checkouts only).
- M8 persistence: layout, prefs, cwds and scrollback survive a full restart.
- M9 terminal fidelity: scrollback, selection, copy mode and search, links, paste, reflow.
- M10 kitty graphics: images and placements, equal to herdr in the manual comparison.
- M11 detection: agent detection with herdr's manifests (idle, working, blocked, done),
  sidebar badges, toasts, `agent.*` API and CLI, manifest hot reload.
- M12 API and CLI: socket API, `dynide <verb>` CLI, event streams.
- M13 chrome: sidebar, tabs, menus, modals, toasts, themes, `config.toml`, keybind UI.
- M14 plugins: herdr's external-process plugin model.
- M16 remote attach: more clients, local or over ssh, with reconnect and kernel-restart survival.
- M17 long tail: zoom, worktrees, navigator, custom commands and popups, drag-reorder,
  notifications and sounds, shell completion.
- M18 release: tarball build, installer, signed `dynide update` through
  `kernel-restart`, Homebrew formula and Nix flake (local), signing scripts, this
  documentation; kernel copy-mode search, herdr's CLI output shape, `plugin update`, kitty
  images across a graceful kernel restart, `t=t` temp-file cleanup, popup env removal.

## Known limitations

Assembled from every "Known gaps" section; internal test and code-hygiene items are
left in the results files. Each entry names its source.

### Distribution

- No hot reload or remote shell in the release; live editing needs a source checkout.
  ([m18 rulings R1, R3](../results/m18.md))
- An update does not replace the running broker binary; broker-side fixes need a full
  stop and start. ([m18 ruling R4](../results/m18.md))
- No update notifications, in-app release notes or announcements; use
  `dynide update --check`. ([m18 ruling R8](../results/m18.md))
- `attach` runs a client VM and, in a source checkout, needs a compiled tree on the
  client machine; the release has no separate client package.
  ([m16](../results/m16.md), note for M18)
- Linux was only run on aarch64 in a VM; no x86_64 build exists (rustc segfaults under
  qemu on the build Mac). The gate's Linux typing max during a flood is 47-608 ms
  (p95 10-13 ms). ([m6-gate](../results/m6-gate.md), [m18-gate](../results/m18-gate.md))
- A demoted Linux flood reader stays at nice 10 without `CAP_SYS_NICE`.
  ([m6-gate](../results/m6-gate.md))

### Sessions and handoff

- A full quit restores layout, cwd and scrollback (last 1000 rows as VT text) but not
  running programs; restore starts `$SHELL`. Kitty images are not persisted.
  ([m8](../results/m8.md), [m10](../results/m10.md))
- Kitty images survive a graceful `kernel-restart` (and `update`) only when placed on the
  active screen or as virtual placements, up to 16 MiB of pixels per pane; images partly
  scrolled off, in scrollback, on the inactive screen or under origin mode are dropped, and
  a crash handoff (`kill -9`) carries none until the child sends them again.
  ([m18](../results/m18.md))
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
- A remote client ignores `[ui.sound] command`; set `DYNIDE_SOUND_COMMAND`.
  ([m16](../results/m16.md))
- The ssh relay finds the server in ssh's non-interactive environment; custom socket
  paths or an off-`PATH` install need `DYNIDE_REMOTE_BIN`. ([m16](../results/m16.md))
- Typing under a 15-pane flood has p50 about 11 ms (idle 0.45 ms). ([m16](../results/m16.md))

### Terminal fidelity

- Case-insensitive copy-mode search folds per character: a query typed with a final
  sigma (`ς`) does not match `Σ`. ([m18](../results/m18.md))
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
  a fraction of a cell); no size cap or per-scene byte budget.
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

- The CLI prints herdr's whole `{"id","result"}` reply (errors `{"error","id"}` on
  stderr), but `plugin list`, `install`, `update`, `uninstall` and `api schema` print it
  where herdr prints human text; request ids are `cli:<method>`, not herdr's per-verb ids;
  keys are sorted. `api call pane.read` answers `{"text"}`, not herdr's `{"read":{...}}`.
  ([m18](../results/m18.md))
- `plugin update` has no fast-forward check (it moves to the ref's tip, as herdr does); an
  `uninstall` or `disable` issued during a long update build is reverted when the build
  registers. Not ported: per-plugin checkout locks across VMs,
  `pane.link.resolve`, stale-target checks on `pane.link.activate`, cleanup of old
  managed installs. ([m14](../results/m14.md))
- Plugin commands have no default timeout (as in herdr); 32 hung commands block plugin
  runs. `pane.exited` and
  `pane.moved` hooks never fire. ([m14](../results/m14.md))
- `pane.read` has no `recent-unwrapped`, `detection` or ANSI source; `pane.process_info`
  has no foreground process list. ([m12](../results/m12.md))
- Each connection has a 1 MiB receive buffer and at most 16 pipelined requests during a
  wait. ([m12](../results/m12.md))
- `pane.swap` lacks herdr's `source_pane_id`/`target_pane_id` form; a paneless
  `notification.show` raises no `notification.shown` event;
  `resume_argv` reports are refused until agent detection claims the pane.
  ([m17](../results/m17.md))
- The CLI caches the Elixir ebin path and does not notice an Elixir upgrade while the old
  directory exists (source checkout). ([m12](../results/m12.md))

### Agents

- Detection manifests update only with a release (or a local override in
  `<config dir>/agent-detection/`); herdr's remote manifest channel is not ported and
  `server agent-manifests` shows its columns as `never` / `not checked`.
  ([m11](../results/m11.md), [m18](../results/m18.md))
- Hook integrations are installed by hand; there is no settings integrations section.
  macOS lists an arbitrary 64-process subset of a foreground job. ([m11](../results/m11.md))

### Reload (source checkouts)

- A blocked source still loads in a new VM after a handoff; other `Server.reload` entry
  points bypass the test gate; reload status does not carry across a handoff.
  ([m7](../results/m7.md))
- `DynideReload.Telemetry.event/2` is outside the guard; a bad edit to it can break the
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
M18 fixed: the 1.1 s copy-mode search miss (now about 23 ms in the kernel, off the client
session), herdr's CLI output shape, `plugin update`, kitty images lost on a graceful kernel
restart, the never-cleaned `t=t` upload directory, popups with `identity: false` inheriting
pane-identity variables, and pane shells inheriting `DYNIDE_BROKER_SOCK`
([m18](../results/m18.md)).

## Pending in this release

Open items of M18 itself ([m18](../results/m18.md)):

- No update channel is published. `releases/<V>/update.url` names
  `https://updates.dynide.invalid/stable/manifest.json`, so a plain `dynide update`
  fails with `fetch_failed` until a manifest is hosted; `--manifest URL` works today.
- Signing and notarization have only been dry-run. A locally built tarball is ad-hoc
  signed, and a quarantined download is refused by Gatekeeper.
- A local build trusts the dev update key from `keygen.sh` only with `build.sh --dev-key`;
  without it and without `DYNIDE_UPDATE_PUBKEY` it trusts no key. A real build must set
  `DYNIDE_UPDATE_PUBKEY` (see [signing.md](signing.md)).
- The Homebrew formula is macOS arm64 only and was tested in a throwaway brew. The Nix flake
  is untested (no nix on the build host). Both install a flat tree, and `dynide update`
  refuses there (`managed_install`). Run `dynide kernel-restart` after `brew upgrade`
  or a nix switch: the running instance is pinned to the old path, which the upgrade (or
  nix garbage collection) deletes.
- Linux needs the OS's `libcrypto.so.3`, `libtinfo.so.6` and glibc 2.39 or newer (Ubuntu
  24.04 has them).
- A killed update leaves `<lib>/.update.lock`; the next run takes it over once its pid is
  gone.
- After a successful `kernel-restart` the updater waits 5 s for the new version to answer.
  A slower takeover reports `restart_did_not_switch`; re-running `update` finishes it.
- Perf and stability: no regression at matched load; every slice-1 row is met on both OSes
  on the release build ([m18-gate](../results/m18-gate.md)). Reload latency for state-shape
  edits grew since M7 and is still inside its targets.
