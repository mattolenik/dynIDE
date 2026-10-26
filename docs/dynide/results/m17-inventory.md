# M17 inventory: the long tail

The list of herdr features and carried items M17 has to close. Each one ends
**done** (commit, test), **dropped** (reason), or **deferred** to a named milestone
(reason). Built from the `herdr-reference` tag's `src/`, every carried, deferred,
not-done and known-gap line in [status.md](../status.md) and results m7 to m13, and the
M17 brief. The plan column says what was planned; the status column is the closed state at
hand-back (Task 26), with commits (current `live/m17` shas) and tests. Results:
[m17.md](m17.md).

Sources for each row: **ref** is a path under `herdr-reference:src/`. **st** is
status.md. **mN** is results/mN.md. **br** is the M17 brief.

Owner gates:
- **M9** marks a row that waits for M9 to land, because it builds on M9's pointer,
  desktop NIF or copy mode.
- **coord** marks a row that edits a file another owner holds; the coordinator clears
  it first.
- Files of landed milestones (M8, M12, M13) are shared files now. Edits to them stay
  small and additive.

## A. Dogfood findings and carried infra

| # | item | source | plan | status |
|---|---|---|---|---|
| A1 | Tty restore that survives a SIGKILLed broker | st (M7 F7), br | The launcher wraps the broker in the existing `scripts/tty_guard.sh` when a tty is present and the run is not headless. The guard already saves `stty -g`, waits, and writes the restore sequence after a signalled or non-zero exit, only while it owns the foreground. Test: a tty_harness mode that `kill -9`s the broker pid and asserts cooked termios and the leave-alt-screen bytes. | **done** `b55edd2a`, `1e57c5b1`; test: `tty_harness.py broker-kill` (in `just live-check`: exit 137, termios equal, leave-alt-screen bytes, `broker_killed` logged; SIGTERM leg logs none) |
| A2 | `log_summary.py` recognises an operator kill | st, br | The guard from A1 knows the broker died by a signal and appends `herdr-event broker_killed ts= signal=N` to the log. The summary counts `operator_kills`. The broker_start that follows a kill is not counted as a loss, and neither are the dying VM's `session_lost` lines in the kill window. Ceiling: an OOM SIGKILL also reads as an operator kill (signal 9 is all the guard sees). Test: `test_log_summary.py` fixture of an F7 sequence. | **done** `d84bca25`, `1e57c5b1`; test: `test_log_summary.py` (`test_operator_kill_is_not_a_loss`, `test_kill_far_from_loss_still_counts`, `test_unclean_restart_without_kill_still_counts`). Only `signal=9` counts as an operator kill (polish); any other signal is a loss |
| A3 | Rejected beams accumulate under `_build/dev/herdr_reload/rejected/` | m7, st, br | Prune at reload-server start: keep the newest 20 batch dirs. Test in herdr_reload. | **done** `5a5f9865`; test: herdr_reload `server_test` "prune keeps the newest 20" |
| A4 | Reload status node does not carry across a handoff | m7, st, br | Dropped. The reload node names a batch of the old VM (`r<N>`) that the new VM cannot roll back, because batch ids, the ring and rollback are per VM. Carrying it would show a rollback target that does not exist. The new VM's handoff node already says what happened. | **dropped** (reason in plan) |
| A5 | Idle API connections wake once a second | m12, br | Dropped. The wake is how a connection loop moves onto reloaded code before a second purge kills it, and its cost is one timer per idle connection. Only `events.subscribe` streams stay idle; CLI calls last about 170 ms. The alternative (the reloader messaging every conn) is more code for no measured cost. | **dropped** (reason in plan) |
| A6 | One `api_connect` log line per CLI call | m12, br | Coalesce: `Api.Listener` emits at most one `api_connect` line per 60 s, with `count=` connects since the last line, plus `conns=`. `log_summary.py` sums `count` (default 1 for old logs). Test: listener unit test and a summary fixture. | **done** `246def84`, `3f4670ee`, `a415d259` (pending count logged at stop); test: `listener_test` (3 connects -> one line `count=1`, 61 s later `count=3`, stop logs the rest), `tty_harness.py agent`, `test_log_summary.py` (sums `count`, default 1) |
| A7 | Two close behaviours (chrome closes the workspace, API keeps a fresh tab) | m13 ruling 26, st | Kept. The coordinator ruled that both stand, and nothing in M17 use found them confusing. | **dropped** (ruling 26 stands) |
| A8 | Adopted exit status `:unknown`; broker as reaper | m5, m8 ("M17") | Dropped. macOS has no subreaper, so this needs the broker to become the pane spawner, which is a broker and kernel redesign. The only user-visible effect is a missing exit code on a pane that exits after a handoff. Revisit if M11 detection needs exit codes. | **dropped** (reason in plan) |
| A9 | Compiler warnings in every compile (`api/conn.ex:122` grouping, three test warnings) | m7, m9 | Group the `line/3` clauses and fix the three test warnings. | **done** `cbfe8a07`; test: `mix compile --force` 0 warnings at the gate (every rebase checked it too) |
| A10 | Test gate bypassed after a handoff or by other `Server.reload` callers | m7 | Dropped. The gate is a dev-only opt-in (default off) and its gaps are documented in editing-live.md. Closing them needs gate state carried across VMs, which is the A4 problem again. | **dropped** (reason in plan) |
| A11 | Unguarded telemetry calls | m7 | Dropped. This is documented in editing-live.md. Telemetry is a two-line logger shim, and guarding every call adds a Guard hop to the Store restart path. | **dropped** (reason in plan) |
| A12 | M8 carried: no directory fsync after rename; Store blocked ~19 ms per pane at restore | m8 | Dropped. The BEAM cannot fsync a directory without a NIF, and rename is already atomic (the loss is limited to a power cut inside the window). The restore blocks once at boot. | **dropped** (reason in plan) |
| A13 | M12 carried: lost events during a Store restart, 1 MiB conn buffer, CLI ebin cache | m12 | Dropped. These are documented ceilings with no user report. Monotonic ids and the Commands/Actions duplication were fixed by M13. | **dropped** (reason in plan) |
| A14 | M13 final-triage minors | m13 | Carried as triaged by M13. M17 fixes any it touches on the way and lists those in results. | **dropped** (triaged by M13; nothing touched) |

## B. CLI and API surface left to M17 by M12

| # | item | source | plan | status |
|---|---|---|---|---|
| B1 | `herdr-live --default-config` | m12 table | A commented `default_config.toml` in herdr_cli priv, printed by the flag. Test: the file decodes to the server's `Config` defaults (herdr_integration). | **done** `67cafbc1`, `6d4469d7`; test: herdr_integration `default_config_test` (two-way: every file key is a server default and every default is in the file) |
| B2 | `herdr-live completion bash\|zsh\|fish` | m12 table | Generated from the CLI's own verb table in `HerdrCli.Argv`; no new dependency. Test: each shell's output names every verb. | **done** `67cafbc1`, `6d4469d7`; test: herdr_cli `completion_test` (each shell names every verb) |
| B3 | `pane split --cwd/--env` | m12 table | Optional `cwd` and `env` on `pane.split`, built on M14's `{:spawn, id, size, opts}` cmd/args/env opts once they are in herdr-live (coordinator seam). Worktrees (D1) use the existing `cwd` opt meanwhile. | **done** `4dfde75b`, `4466597b` (on M14 spawn opts); test: `api/topology_test` (cwd absolute existing dir, env map, NUL and bad keys are `invalid_params`), argv tests |
| B4 | `pane.focus_direction`, `pane.swap`, `pane.resize`, `pane.zoom` by id | m12 table | Thin handlers over the existing focus_dir/swap_dir/resize_dir actions and the new zoom (C1). | **done** `4dfde75b`, `4466597b` (focus/swap/resize; `amount` is herdr's float fraction), `2bc93dea` (zoom); test: `api/topology_test`, cli conformance. Gap: herdr's `source_pane_id`/`target_pane_id` form of `pane.swap` |
| B5 | `pane.neighbor`, `pane.edges` | m12 table | Dropped. These are geometry queries with no consumer; `pane.layout` already returns the rects. | **dropped** (reason in plan) |
| B6 | `pane.move` | m12 table, ref layout.rs | Dropped. It is API-only in herdr (no keybind or chrome), needs layout tree surgery across tabs, and has no consumer. Add it when an agent workflow needs it. | **dropped** (reason in plan) |
| B7 | `pane.rename` | m12 table | Moved to M14 (coordinator seam): M14 lands `pane.rename` in its early contract commit. | **M14** (landed in M14's contract commit) |
| B8 | `notification show` / `notification.show` | m12 table (deferred M13; M13 added only the `notification.shown` event) | Handler that raises an `{:alert, %{kind: :notification}}` through `App.Alerts`. | **done** `64a3b891`; test: `api/events_test`, `app/alerts_test`, `client/toasts_test`. A paneless notification raises the toast but no `notification.shown` event (deferred minor) |
| B9 | `title set/clear` (`client.window_title.*`) | m12 table, ref cli/title.rs | With C6. | **done** `faa8cfb2`, `6b7528b5` (with C6) |
| B10 | `events.wait` | m12 table | Dropped. `events.subscribe` plus `pane wait-output` cover the uses (M12's note), and `subscribe | head -1` is the CLI equivalent. | **dropped** (reason in plan) |
| B11 | `tab.move`, `workspace.move` | m12 table | With C3. `workspace.move_block` is dropped: worktree groups do not exist as blocks here (D1 keeps worktree workspaces flat). | **done** `1dc3c491`, `1703d8b1`, `848bd0f4`, `fc34047b` (with C3; herdr `insert_index` gap semantics, `tab.moved`/`workspace.moved` events); test: `api/topology_test`, `event_diff`/events tests. `workspace.move_block` **dropped** |

## C. Chrome and UX left by M13

| # | item | source | plan | status |
|---|---|---|---|---|
| C1 | Pane zoom (`prefix+z`, `zoom` action, tab zoom indicator) | m13 not done, ref layout.rs | `zoomed` per tab in `App.Session` (Schema migration), `Actions.toggle_zoom`, and View lays out only the zoomed pane. Zoom is cleared on split, close and focus moves out of the pane, as herdr does. | **done** `20482e43` (contract, upstream), `7127302f`, `2bc93dea`; test: `layout_test`, `app/actions_test`, `view_test`, `server_test` (vt resized, other panes hidden and restored), `schema_test` |
| C2 | Workspace names from cwd / git | m13 sidebar row, ref workspace.rs, workspace/git/discovery.rs | A pure `Workspaces.Label.auto(cwd)`: a linked worktree uses its checkout dir name, else the repo root basename, else the basename. Applied while no custom name is set, re-derived when the first pane's cwd changes. Needs a persisted `custom_name?` flag. | **done** `aef8dfbb`, `9bc97d1d` (schema v4 `auto_name`); test: `app/workspaces/label_test`, `workspace_facts_test`, `workspaces_test`, `persist/schema_test` |
| C3 | Drag-reorder of tabs and workspaces | m13 not done | Tab and workspace hits get `drag: true`; `App.Chrome` handles `:drag`/`:drop` on them and reorders `App.Session`. An insert marker uses a prop on the tab or item node, so there is no new role. `tab.move`/`workspace.move` API (B11). | **done** `20482e43` (contract), `1dc3c491`, `1703d8b1`, `848bd0f4`, `fc34047b`; test: `app/chrome_test`, `view_test` (marker per client), `server_test` (two clients: only the dragger sees the marker), term `hit_test` |
| C4 | Hover highlights (menus, tabs, sidebar rows) | m13 not done | Client-only presentation. The term client keeps the pointer cell from M9's any-motion events, and Render highlights the hit under it with `:selected`. No server state and no contract change. | **done** `d2505b9c`, `e7539fd4`, `ececcf4d` (live since M9's `?1003h`); test: term `render/chrome_test` and `chrome/sidebar_test` (hover tint, wide glyph, menu layer), `input_test` (hover goes to Render only on change, never to the server) |
| C5 | Tab bar `hide_when_single_tab`, `tab_bar_position` top/bottom | m13 not done, ref config/tab_bar.rs | Two `App.Ui` keys from config.toml, read by View's frame layout. `tab_bar_right` entries (clock, hostname, command) are dropped: herdr-live's permanent status row (M13 ruling 2) is the place for them, and none was asked for. | **done** `144da146`, `cd6ea1cb`; test: `view/frame_test`, `app/actions_test` (reframe on tab count change), `config_test`, `upgrade_test`. `tab_bar_right` **dropped** |
| C6 | Window title (`ui.window_title` template `{hostname}: {workspace}`, `{tab}`, `{pane}`, `{terminal_title}`) | ref app/window_title.rs, config/window_title.rs | Server renders the template into a root prop `window_title`; the term client writes OSC 0 when it changes (sanitised, 200 cap). `title set/clear` (B9) overrides it per client. | **done** `20482e43` (contract), `faa8cfb2`, `6b7528b5`; test: `view/window_title_test`, term `render_test` (OSC 0 on change, clear), `tty/owner_test` (title reset at exit), `server_test` |
| C7 | `pane_borders` auto / always / off | m13 not done | An `App.Ui` key; View drops the border inset under `off`, or under `auto` with one pane. | **done** `7127302f`; test: `layout_test` (`:off`, `:always`, `:auto`), `config_test`, `upgrade_test` |
| C8 | Go to navigator (`prefix+g`) | m13 not done | A `Modal.Goto` kind: a filterable list of workspaces, tabs and panes, reusing Menu rows and `Modal.TextField`, where Enter focuses the target. The agent-state filters (b/w/i/d) and attention sort are deferred to M11, because agent states do not exist yet. | **done** `c12d5f27`, `a59bba85`, `d57eb3ec`; test: `app/modal/goto_test`, `view_test`, fixtures `modal_keybinds_120x40` and others regenerated. Agent filters and attention sort: **M11** |
| C9 | Navigate mode (`prefix+w`, highlight workspaces, Enter activates) | m13 not done | A `:navigate` mode in `Client.Keys` with the preview in `Client.State` and Up/Down/Enter/Esc. Prefix hints gain `w workspace nav`. | **done** `c12d5f27`; test: `client/session_navigate_test`, `client/keys_test`, sidebar tests |
| C10 | `:system` toast delivery | m13 not done, ref client/notifications.rs | Desktop notification through the herdr_term NIF's desktop helper (M9's clipboard tool runner): `osascript display notification` on macOS, `notify-send` on Linux, with no click-through (ceiling). | **done** `921c8672`; test: term `render_sound_test` (`:system` calls the notifier), cargo herdr_term notify argv tests (macOS; Linux cfg-gated). No click-through (ceiling) |
| C11 | Terminal delivery: OSC 99 for kitty, tmux passthrough | ref terminal_notify.rs | Backend detection from `TERM_PROGRAM`, `KITTY_WINDOW_ID` and `TERM` in the term client's alert path, DCS-wrapped under `$TMUX`. | **done** `921c8672`, `40f925d1`; test: term `notify_test` (detection table), `alert_test` (OSC 9/99 bytes, tmux DCS wrap), `render_test` (tmux in kitty) |
| C12 | Toast 1 s delay with re-check | m13 not done, ref notification_policy.rs | Deferred to M11. The re-check drops a toast when the pane is no longer done or is focused, which needs agent states. The `delay_ms` config is already read. | **M11** (needs agent states) |
| C13 | Built-in sounds (done / request) | m13 toast row, M17 scope "sound", ref sound.rs | Ship herdr's two sound files in herdr_term priv and play them through the same desktop helper (`afplay`; `paplay` or `pw-play` on Linux) when `sound.command` is unset, else BEL. Adds `done_path`/`request_path`. Per-agent overrides are deferred to M11 (they key on agent kind). | **done** `921c8672`, `40f925d1` (config-dir-relative paths, reload drops removed paths); test: `render_sound_test`, `config_test`. Per-agent overrides: **M11** |
| C14 | Mobile layout (cols <= threshold) | m13 not done, br | Deferred to M15. A phone reaches herdr-live over SSH or remote attach (M16), and how a narrow or touch client presents the session is the client-technology question the M15 ADR settles. The terminal client already renders at any width. | **M15** |
| C15 | Settings `integrations` section, agents sort label | m13 not done | Deferred to M11 (agent integrations and agent states). | **M11** |
| C16 | `custom` keybind group in help | m13 not done | With D3. | **done** `85bc4e9c`; test: `app/custom_commands_test` ("help lists custom") |
| C17 | Rebinding indexed `switch_tab` | m13 not done | Dropped. `prefix+1..9` work, and rebinding them needs an indexed-action catalog shape for little gain. | **dropped** (reason in plan) |
| C18 | Prefix hints not width-budgeted | m13 | Truncate the hint list to the status width in `View.Status`. | **done** `694095f0`; test: `view_test` (hints fit the status row at 40 cols) |

## D. herdr features from `src/`

| # | item | source | plan | status |
|---|---|---|---|---|
| D1 | Git worktree management: `worktree list/create/open/remove`, `new_worktree` (prefix+G), open/remove keybinds | ref worktree.rs, app/api/worktrees*, client/shell/worktrees.rs; br; m12 table | `HerdrServer.Worktree`, pure argv building and porcelain parsing plus `System.cmd("git", ...)` behind the Guard. Default path `<worktrees.directory>/<repo>/<branch-slug>` as herdr (config `[worktrees] directory`; herdr-live default `~/.herdr-live/worktrees`). API, CLI and Spec verbs. Create and open start a workspace in the checkout (B3 cwd), named by C2. Remove asks through `Modal.Confirm` (force confirm when dirty), closes the workspace, and never deletes the branch. Overlays reuse `Modal.Prompt`/`Menu`/`Confirm`. | **done** `fee407e5`, `22215af9`, `f738890c`, `baeef81e`; test: `worktree_test` (argv, porcelain, slug, no-git), `app/worktrees_test`, `api/worktrees_test` (each verb on tmp repos), api conformance. Slug follows herdr's `branch_to_path_slug` exactly (ruling) |
| D2 | Git branch and ahead/behind per workspace | ref app/git_refresh.rs, workspace/git/* | One `git status --porcelain=v2 --branch` per workspace identity cwd, run by a small poller (5 s, change-only, a timeout per call, skipped while nothing is shown). Results go into workspace facts, rendered as the sidebar branch token. The `.git/config` parser and the 5 min discovery cache are dropped: one porcelain call gives both. | **done** `2875a832`, `f1b0e842`, `a212c5bc`; test: `git_status_test`, `workspace_facts_test` (change-only, a hung call started once, a dead call process recovers), sidebar tests |
| D3 | Custom commands `[[keys.command]]` (`shell`, `pane`, `popup`, `plugin_action`) | ref app/custom_commands.rs, config/keybinds.rs | Parsed in `Store.Config` into MFA keybinds that call `App.CustomCommands.run/2`. `shell`: a detached `sh -c` with the HERDR_* env (workspace, tab, pane, cwd, bin, api). `pane`: a split running the command. `popup`: D4. `plugin_action`: the parser calls M14's `HerdrServer.Plugins.Keybind.mfa(command)` and applies the MFA (coordinator seam). | **done** `85bc4e9c`, `5cec2d2a`, `af83f310`, `5278c0ff` (one parser; M14 stopgap removed); test: `app/custom_commands_test`, `config_test` |
| D4 | Popups (custom command `type = "popup"`, sizing `width`/`height` cells or `%`, `popup.close`) | ref app/popup.rs, popup_size.rs | A `Modal.Popup` kind that owns one pane outside the tree. The modal stack already routes keys to the top modal, so the popup forwards them to its pane. View places the pane at the modal rect with the sizing ported from popup_size.rs. Closing it, or the command exiting, pops the modal and closes the pane. `popup.close` API. | **done** `4aaee351` (pane `layer` contract, upstream), `79652b38`, `10babe23`, `746711e2`, `19e51ace`, `9184ae0d`, `b40208bc`, `94cc892a`, `d9fa8762`, `301975f5`; test: `app/modal/popup_test` (popup_size.rs tests verbatim), `app/store/carry_popup_test`, `reconcile_test`, `pointer_test`, term compose popup tests, fixture `popup_120x40`, plugins `panes_test`. Kernel env removal for `identity: false` popups: **M18** |
| D5 | Metadata tokens: `pane report-metadata`, `workspace report-metadata` (ttl, seq), rendered in the sidebar | ref metadata_tokens.rs, ui/sidebar/tokens.rs; m12 table; br | Server facts: a metadata map per pane and workspace with expiry and per-source seq, not persisted (TTL data). API and CLI verbs; the sidebar shows reported tokens after the built-ins, joined by ` · `. Configurable row layouts and style rules (`[ui.sidebar.*]`, 16 rules per token) are dropped for M17: no config uses them yet, and M14 plugins (the reporters) can ask for them. | **done** `caf41cdc`, `8043ae4f`, `ca9f5b26`; test: `app/metadata_test`, `api/topology_test`, `persist/schema_test` (not persisted), sidebar tests. Row layouts and style rules **dropped** |
| D6 | Agent resume on restore | ref agent_resume.rs, app/agent_resume.rs; m8; br | Plumbing only, with the UI gated on M11. A pure `AgentResume.plan/1` builds per-agent resume argv (claude, codex, droid, pi/omp, opencode, or a reported argv), with herdr's validation (64 args, 8 KiB, no control chars, a plain command name) and POSIX quoting. A persisted per-pane `agent_session` (Schema migration) and `pane.report_agent_session` API. On a disk restore with `session.resume_agents_on_restore = true` (default false), the command is typed into the respawned shell, spaced by `startup_per_agent_delay_ms`. The hooks that report sessions (integrations) are M11's. | **done** `e5ca46df`, `e8333150`; test: `agent_resume_test`, `persist/restore_plan_test`, `persist/store_restore_test`, `schema_test`. Reporting hooks: **M11** |
| D7 | Update notifications for the new channel | br, ref update.rs | Deferred to M18, which chooses distribution. The seam already exists: `ping` returns the version, and an `{:alert, %{kind: :notification}}` (B8) is how a check result reaches every client as a toast. M17 adds no checker code without a manifest to check. | **M18** |
| D8 | Release notes display | m13 not done, ref release_notes.rs, ui/release_notes.rs | Deferred to M18. The notes come from the release artefact, and the display is a `Modal` kind plus a seen-version `App.Ui` key once there is content to show. | **M18** |
| D9 | Product announcements | br, ref product_announcements.rs | Deferred to M18 (or dropped). They ride on herdr's update manifest, and the fork has none. | **M18** |
| D10 | Copy-mode search | br, ref client/shell/copy_mode.rs | Done by M9 (`/ ? n N`, smart case, `:search_match` overlay; m9 item 2). M9 recorded the residual ~1.1 s miss over 20 000 rows and the missing wrap-around. After M9 lands, M17 adds wrap-around (herdr wraps) in `CopyMode.search`. The 1.1 s miss needs a kernel search, which goes to the coordinator as an M9 follow-up. | **done** (wrap) `029cc5ee`; test: `client/copy_mode_test` "wrap-around". Kernel `Native.Vt.search/3` and search off the Session: **M18** (ruling) |
| D11 | Theme sync (host light/dark, DSR 996/2031, OSC 10/11) | ref app/theme_sync.rs | Done by M9 (host colours and scheme caps) with M13 (Detect, auto_switch). M17 verifies it after the rebase. | **done by M9/M13**; their tests pass on the rebased branch, no separate M17 check |
| D12 | Open scrollback in editor | ref app/custom_commands.rs | Dropped. Copy mode (M9) and `pane read --source recent` cover reading history, and nobody asked. | **dropped** (reason in plan) |
| D13 | Input lease (kitty release/repeat pairing) | ref input/lease.rs | Dropped. The term client never enables kitty release reporting on the host, so no release events arrive to pair. | **dropped** (reason in plan) |
| D14 | Remote machines, session list/attach, terminal streams, `api snapshot` | ref remote/*, m12 table | Owned by M16. | **M16** |
| D15 | Agent detection, `agent.*`, integrations, manifests | ref detect/*, integration/* | Owned by M11. | **M11** |
| D16 | Plugins | ref plugin_* | Owned by M14. | **M14** |
| D17 | Kitty graphics, clipboard images | ref kitty_graphics/*, client/clipboard_images.rs | Owned by M10. | **M10** |
| D18 | Self-update, `--version`, channels | ref update.rs, build_info.rs | Owned by M18. | **M18** |

## Contract changes expected (published early, own commit)

These are the only `herdr_scene` changes the rows above need. All are additive and
optional. They go in one SPEC_PUBLISHED commit before the items that use them:

- root prop `window_title` (C6);
- an optional `drop_marker` prop on `:tabs` tab and sidebar `:item` nodes, and a
  `zoomed` prop on a tab node (C1, C3);
- for popups (D4), an optional pane layer or a modal-anchored pane, depending on the
  plan; it may turn out unneeded if the modal's rect plus the existing pane list is
  enough.

## Order

1. A1, A2, A3, A6, A9 (infra), then B1, B2, B7, B8 (thin API/CLI).
2. Contract commit (SPEC_PUBLISHED), then C1, C5, C6/B9, C7, C18.
3. C2, D2, B3, then D1 (worktrees).
4. D3, then D4 (popups); D5; D6.
5. C3, C8, C9.
6. After M9 lands: C4, C10, C11, C13, D10 wrap.

## Deferred to M18 during M17 (coordinator rulings)

| item | reason |
|---|---|
| Kernel `Native.Vt.search/3` with a budget, and search off the Session (M9 gap: about 1.1 s for a miss over 20 000 rows) | A new kernel NIF needs handoff work beyond the long-tail budget. D10's wrap keeps the 20 000-row total budget, so the worst case is unchanged. |
| herdr's `{"result": ...}` CLI envelope (M14 ask) | It changes every CLI output (harness, scripts, conformance fixtures) and needs its own compatibility pass. |
| `plugin update` (M14 ask) | Needs fetch and version flows beyond M17's inventory. |
| M10: carry kitty images across a handoff; clean up the per-user `t=t` temp dir | Kernel and graphics owned, not in this inventory. |
| Kernel env removal for `identity: false` popups (D4) | herdr gives a popup no pane identity. Here `identity: false` only keeps the Store from setting `HERDR_PANE_ID`/`HERDR_TAB_ID`/`HERDR_WORKSPACE_ID`; the kernel spawn can only set variables, so one the VM inherited stays. Removing it is a kernel spawn-opt change (a NIF, so a handoff, not a reload). |
