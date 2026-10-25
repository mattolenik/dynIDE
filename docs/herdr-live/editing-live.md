# Editing herdr-live from inside herdr-live

herdr-live is developed in a herdr-live pane: an agent edits `live/apps/*/lib`, saves,
and the running multiplexer picks the change up without losing terminals, scrollback or
layout. A bad edit is rolled back; it does not take the session down. This guide is the
long form of the "Editing herdr-live from inside herdr-live" section of
[AGENTS.md](../../AGENTS.md). Rules come from [design.md](design.md) ("Hot reload"); the
measured behaviour is in [results/m4.md](results/m4.md), [results/m5.md](results/m5.md)
and [results/m6-gate.md](results/m6-gate.md).

## The loop

1. Start herdr-live: `just live-run` (or `live/bin/herdr-live`). Work inside a pane.
2. Edit a file under `live/apps/<app>/lib/` and save.
3. The Watcher (it watches `apps/*/lib` only) debounces 50 ms and hands the paths to
   `HerdrReload.Server`, which drives Mix's incremental compiler in the VM, diffs the
   beams and loads the changed modules as one batch (soft purge, `load_binary`).
4. The status line shows the result. Typical latency on macOS (results/m6-gate.md):
   `Client.Term.Render` 288-296 ms and `View.compute` 186-196 ms from save to visible.
5. Check your change on screen, or run the focused test: from `live/`,
   `mix test apps/<app>/test/<file>_test.exs`.

Never use `Code.compile_file`; structs, macros and protocols are compile-time
dependencies and only Mix's compiler recompiles dependents.

The reload pipeline runs only in the primary VM. The warm standby VM does not run it.

## What reloads and what needs `kernel-restart`

| change | how it takes effect |
|---|---|
| any `.ex` under `live/apps/*/lib` (server, term, scene, reload) | save; hot reload |
| `herdr_reload` itself | save; it is reloadable, but a mistake in it is not guarded by itself |
| NIF Rust code (`live/native/herdr_kernel`, `herdr_term`), libghostty-vt | rebuild, then `live/bin/herdr-live kernel-restart` (graceful handoff to a fresh VM, children keep running; input is queued and replayed. The handoff window was 7-12 ms (results/m6-gate.md); the whole `kernel-restart` took 1417 ms wall in the typing bench under load, results/m5.md `restart_wall_ms`) |
| `live/native/herdr_broker` | restart herdr-live (the broker is the process supervising the VMs) |
| `config/*.exs`, `mix.exs`, new deps | restart herdr-live (a dep added mid-session needs a VM restart) |
| Elixir tests only (`apps/*/test`) | not watched; run `mix test` yourself |

NIF modules are never hot reloaded. A new `#[rustler::nif]` also needs the Elixir stub in
the crate's NIF module and a facade function (see AGENTS.md "Adding a NIF").

## Fan-out and why `herdr_scene` edits are expensive

The cost of an edit is its dependency fan-out: Mix recompiles every module that depends
at compile time on what you changed (struct literals, macros, `use`, behaviours,
protocol impls). The status line shows it as `r<batch> <k>m` where `k` is the number of
modules that changed.

Measured on macOS (results/m6-gate.md): adding a field to `App.Ui` fans out to 3 modules,
`App.Session` to 2, and a `HerdrScene` struct to 3+1 modules across `herdr_scene`,
`herdr_server` and `herdr_term` (about 470 ms to loaded). `herdr_scene` is the one
contract every app depends on, so an edit there recompiles server and clients and
reloads both. Keep it small, avoid editing it casually, and batch related scene edits in
one save session. Per-client presentation state belongs in `Client.State`, not `App.*`,
precisely so a presentation tweak does not fan out through the server.

## State shape changes and `code_change/3`

A running GenServer keeps its state across a reload. If you add a field to its struct:

- every callback must begin `state = Map.merge(%Struct{}, state)`, so a state built by
  the old code gains the new field's default;
- give the module a `code_change/3` that merges the new defaults (see
  `HerdrServer.ReloadNotices.code_change/3` for the pattern, including converting an
  older state shape);
- never put a local `fn` in persisted state (a closure ties the state to one module
  generation). Keybinds are `{M, F, A}` tuples.

If the old code fails on state the new code corrupted, the Store restores `state_at_load`
and reconciles with `Native.Keeper`: panes spawned in the window are adopted into a
"scratch" tab, panes whose kernel is gone are dropped. Terminals are untouched in every
case.

## Session persistence

Under `bin/herdr-live` the session (layout, focus, ui prefs, pane cwds) is saved to
`<state dir>/session.<name>.etf` (ETF, schema v2, atomic temp+rename, 0600) and the last
1000 rows of each pane's scrollback to `session.<name>.scrollback/<pane id>.etf`. The state
dir is `HERDR_LIVE_STATE_DIR`, else `$HERDR_LIVE_RUNTIME_DIR/state` when a runtime dir is set,
else `${XDG_STATE_HOME:-~/.local/state}/herdr-live`; the name is `HERDR_LIVE_SESSION`
(default `default`). Tests and standalone `mix run` never persist.

- What survives a stop/start: workspaces, tabs, split layout, focus, ui prefs, titles, and
  scrollback. Panes come back as new `$SHELL`s in the recorded cwd (nearest existing ancestor
  if it is gone), with history replayed above the prompt. The recorded command is never
  re-run. Keybinds and the modal stack are not persisted. Running processes do not survive
  a stop (a `kernel-restart` handoff keeps them).
- Restore precedence at `App.Store` init: broker carry (handoff) > ETS mirror (Store
  restart) > disk (fresh start, and the broker's fallback after 3 failed adoptions, logged
  `reason=fallback`).
- Start fresh: run with `HERDR_LIVE_PERSIST=0`, or stop herdr-live and move the session
  file away.
- Bad files are moved aside as `session.<name>.etf.bad-<ms>` (newer schema:
  `.v<N>-<ms>`) with their scrollback dir; 5 are kept. A restore that crashes the Store sets
  the file aside instead of looping.
- Schema rule: the persisted shape is `HerdrServer.Persist.Schema`. A new `App.Ui` field
  persists generically (plain data only). A new session fact (in `App.Session` or pane
  metadata) needs a schema field and a migration (`@migrations`, bump `version/0`).
- Telemetry: `persist_write`, `persist_restore source=disk|none reason=boot|fallback panes=
  scrollback= ms=`, `persist_error op= reason=`; `just live-log-summary` reports restores,
  persist_writes, persist_scrollback_writes and persist_errors.
- Warning: two instances sharing a state dir and session name clobber each other's file.
  Give each its own `HERDR_LIVE_STATE_DIR` (smokes, harness and benches do) or session name.
  Proof of stop/start: `python3 live/scripts/tty_harness.py persist` (part of `just live-check`).

## The guard boundary

Every call from a thin GenServer into editable code goes through `HerdrReload.Guard`
(`run/4`, `run_twice/4`). The Guard is the only place a blanket `rescue`/`catch` of raise,
throw and exit is allowed. It:

- catches raise, throw, exit; `View.compute` and `Compose.screen` run with a 50 ms
  budget in a monitored worker (a hang is a failure, not a wedge); other calls run inline;
- attributes the failure to the newest live batch whose modules appear on the stack
  trace, rolls that batch back synchronously, and re-runs the call once on the restored
  code (the re-run is never blamed on another batch);
- scans results that become state for local funs and rejects them (`{:rejected, ...}`).

Do not add your own `rescue` around editable code; call it through the Guard instead.

`HerdrReload.Telemetry` is called outside the guard (Store init, the client Endpoint,
`HerdrServer.Application`, `Handoff.Notice`, and the Guard's own failure path), so a raise
there is not rolled back and can take those processes down. Keep edits to it trivially
safe.
Hangs inside `Actions.apply` or the Store have no budget (a known gap): a loop there
wedges that process until its callers time out.

A batch stays attributable until its modules have handled enough guarded calls (20
successes) and 5 s have passed; the ring is 8 batches deep. So a bad edit to a rarely
used feature is still blamed on the right batch when you finally use it, unless more
than 8 reloads happened since.

## Chrome layout and the config file (M13)

The screen is herdr's: a 26-column sidebar on the left (spaces and agents; `prefix b`
toggles, drag its `│` edge to resize, `«`/`»` collapses), a tab bar on the top row of the
main area (`+` opens a "new tab" prompt), and herdr-live's own full-width status row at the
bottom (mode, the runtime texts below, notices, hint). Chrome is a scene tree built by
`HerdrServer.View.*` and drawn by `HerdrTerm.Client.Term.Render.Chrome.*`; editing either
reloads like any other module (an edit to a chrome rasterizer shows at the next chrome
change, which the reload notice itself causes). Modals (confirm, prompt, menus, settings
`prefix s`, keybinds `prefix ?`, onboarding) live in `App.Focus.modal`; while one is open,
keybindings do nothing except detach, and API requests still apply.

Config: `$HERDR_LIVE_CONFIG`, else `${XDG_CONFIG_HOME:-~/.config}/herdr-live/config.toml`
(herdr's TOML format, herdr's `[keys]` syntax). A missing file shows onboarding once;
`continue` writes `onboarding = false`. `prefix R` reloads; a file that fails to parse keeps
the running config and shows one warning. Settings and keybind edits are written back in
place. Scripts that drive the launcher export `HERDR_LIVE_CONFIG` with `onboarding = false`.

## Reading the status line

The `:status` chrome node shows up to three runtime nodes in priority order reload >
tests > handoff, dropping from the lowest when the line is narrow. Texts, exactly:

| text | meaning |
|---|---|
| `r<N> <k>m` | batch N loaded, k modules |
| `r! compile` | compile error; nothing loaded, previous code still running |
| `r<N> rolled back: <reason>` | batch N was rolled back; reason cut to 24 chars (`manual`, or the Guard failure such as a raise message or `timeout`; `(load errors)` is appended when the rollback itself had load errors) |
| `synced <k>m, no rollback` | a promoted standby loaded k modules from disk (see below) |
| `r rejected` | a local fun was found in state; the module's batch was rolled back |
| `r blocked` | purge blocked: a process still runs old code of a module, so it was not loaded |
| `tests...` | test-on-save is running |
| `tests ok` | the mapped tests passed |
| `tests <n> failed` | n failures; the save was not loaded |
| `tests error` | the tests exited non-zero without a failure count (a compile error in the test, a timeout, `mix` not found); not loaded |
| `handoff...` | a handoff started, or is in the `:begin`/`:released` phase |
| `handoff aborted` | the restart failed and the old VM resumed |
| `handoff g<gen>` | adopted by generation `gen` (no kind known) |
| `handoff crash g<gen>` / `handoff graceful g<gen>` | adopted after a `kill -9` / a `kernel-restart` |

The reload and tests nodes stay until replaced. The handoff node expires after 30 s.

Alongside, a transient notice is shown (`HerdrServer.ReloadNotices`, one line, at most
80 characters). Info notices expire after 3 s, warnings after 8 s, and reload errors stay
until the next notice:

| notice | level |
|---|---|
| `reloaded <k> modules` | info |
| `<file>:<line>: <message>` (compile error) | error |
| `rolled back batch <id> (<k> modules): <reason>` | warning |
| `rejected: local fun from <Module> at <path>` | warning |
| `synced <k> modules from disk, no rollback` | warning |
| `purge blocked: <Module> still running in <n> processes` | warning |
| `tests passed (<n> files)` | info |
| `tests failed: <n> failures, not loaded` | warning |
| `tests error, not loaded` | warning |

Compile errors show file and line of the first diagnostic; the full text is in the log
(`herdr-event compile_error`).

## Rollback, what it leaves on disk, and re-saving

Rollback (automatic, or `live/bin/herdr-live rollback [n]` for the newest n batches;
replies `ok <batch ids>`, `ok none` or `error ...`, through the local API socket of
the primary VM) reloads each module's previous beam and also writes it back to its ebin
path. What it leaves:

- the bad beam moves to `<mix build path>/herdr_reload/rejected/<vm_stamp>-<batch>/`
  (in dev: under `live/_build/dev/`). A module that was new in the batch keeps only the
  rejected copy. Look there to diff what was rejected.
- your source file keeps the bad edit. Nothing is reverted in git or in the editor.
- the reloader remembers each source's content. After a rollback, **only a change to the
  source's content reloads it again**: re-saving the same bytes, or touching the file,
  does nothing (that is deliberate; otherwise a rolled-back edit would reload and fail in
  a loop). Edit it to fix it, or revert it, and save.
- an unrelated later reload does not bring the bad code back, but a later batch can
  recompile a compile-time dependent of the rolled-back source from that still-bad source
  (Mix manifest semantics). Fix or revert the source, do not leave it.
- restarting the VM loads whatever is on disk, which after a rollback is the rolled-back
  beams until the source is recompiled.

## Promotion sync: why it has no rollback

A crash handoff promotes the warm standby VM, which booted earlier with older code.
When its reload server starts at promotion it loads every loaded module whose on-disk
beam differs from the loaded one (never NIF modules), about 3 ms. Those loads belong to
no batch: a failure in them is unattributed, so there is no automatic rollback and
`herdr-live rollback` cannot undo them. They are the same beams a cold-booted VM would
load.

You see `synced <k>m, no rollback` in the status line (shown once, when no reload entry
exists yet), the warning notice, and `herdr-event sync modules=... count=... failed=...`
in the log. If something breaks right after a crash handoff, check the sync line first,
and fix the source and save to get a normal, rollbackable batch.

## Test-on-save

Off by default. It adds about a second per save, so it is for risky edits.

- On: `live/bin/herdr-live test-on-save on`, or start with `HERDR_LIVE_TEST_ON_SAVE=1`.
  Off: `... test-on-save off`. `... test-on-save` or `status` prints `ok gate` or `ok off`.
- Mapping: `apps/<app>/lib/x.ex` (or `lib/<app>/x.ex`) runs `apps/<app>/test/x_test.exs`
  when it exists; a saved test file maps to itself. No mapped test: reload as usual
  (`tests result=none`; the status line drops its tests node, no notice).
- The tests run in a separate `mix test` OS process (`MIX_ENV=test`, broker and API
  env removed, 120 s timeout) before compile. Only a pass loads.
- A failing or erroring run blocks the load and keeps the path blocked. Every later gated
  save re-runs the blocked paths' tests too; a pass loads everything and clears the set.
  A failing save leaves the source on disk but not loaded, so the running code stays old.
- The Watcher watches `apps/*/lib` only. After fixing a test, saving the test file alone
  does nothing: re-save a lib file.
- If a source under `apps/*/lib` changes while the tests run, the pass is not loaded
  (`tests result=stale`) and the newer save's batch gates it.
- The gate holds only inside the VM that ran it. A blocked (failing-tests) source is
  still on disk: a new standby VM (`mix run`) compiles it, and a crash promotion's sync
  or the next ungated batch in a new VM loads it; the blocked set does not survive a
  handoff. Fix or revert a blocked source before `kernel-restart`.
- The runtime setting does not survive a VM handoff; the new VM falls back to
  `HERDR_LIVE_TEST_ON_SAVE` or config. After `kernel-restart` or a crash, run
  `test-on-save on` again. Turning it off clears the blocked set (the next save loads
  whatever is on disk).
- Cost, measured on `view.ex` (n=5): save to "tests passed" median 861 ms, save to loaded
  median 981 ms (results/m7.md, Task 6 bench `bench/reload/test_gate_bench.exs`), against about 190 ms without the gate (results/m6-gate.md).

## Driving herdr-live from a pane

The launcher exports `HERDR_LIVE_BIN` (absolute path of `live/bin/herdr-live`) and
`HERDR_LIVE_API` (the resolved API socket) before starting the broker, and the server
gives each pane shell `HERDR_PANE_ID` (`p<N>`). An agent in a pane drives this instance
with `"$HERDR_LIVE_BIN" <verb>`; output is JSON on stdout (`pane read`: text), errors are
JSON on stderr with exit 1, usage errors exit 2.

- `pane split [<pane_id>] --direction right|down`: prints `pane.pane_id` of the new pane.
- `pane run <pane_id> <command>`, `pane send-text`, `pane send-keys`.
- `pane wait-output [<pane_id>] --match S [--timeout MS]`, `pane read [<pane_id>]`
  (omitted id: `$HERDR_PANE_ID`).
- `pane list`, `pane current`, `workspace ...`, `tab ...`, `events subscribe ...`.
- `agent ...` answers `not_available` until M11 detection.

Every verb, param and error: [api.md](api.md). `herdr-live help` lists the verbs.
`python3 live/scripts/tty_harness.py agent` (in `just live-check`) runs this loop.

## Telemetry

Every reload event is a one-line `herdr-event <kind> ts=<unix ms> k=v ...` in the log
(`$HERDR_LIVE_LOG`, default `${XDG_STATE_HOME:-$HOME/.local/state}/herdr-live/herdr-live.log`).
Values that are not `[A-Za-z0-9_.:/@+-]*` are double-quoted (and cut to 300 bytes);
lists are comma-joined.

| kind | when | keys |
|---|---|---|
| `vm_start` / `vm_stop` | VM up / down | `vm_start`: `gen` `role` `adopt` (`fresh`/`crash`/`graceful`); `vm_stop`: `gen` |
| `reload` | a batch loaded | `batch` `fanout` `modules` `compile_ms` |
| `compile_error` | nothing loaded | `file` `line` `count` `msg` |
| `rollback` | batch rolled back | `batch` `fanout` `modules` `reason` (`manual`/`raise`/`throw`/`exit`/`timeout`/`local_fun`/`other`) `detail` |
| `rejected` | local fun in state | `module` `path` |
| `purge_blocked` | old code still running | `module` `holders` |
| `sync` | promotion sync | `count` `modules` `failed` |
| `tests` | test gate | `result` (`passed`/`failed`/`error`/`none`/`stale`) `files` `failures` `ms` |
| `guard_failure` | a guarded call failed | `mfa` `kind` `attributed` (batch id or `none`) `detail` |
| `handoff` | handoff phase | `phase` `gen` `panes` |
| `crash` | Store/session/local client restarted | `proc` `reason` `action` (`restored`/`restarted`/`gave_up`/`none`) |
| `broker_handoff`, `broker_handoff_failed` | broker, per handoff | `kind` `from` `to` `entries` `ms` / `reason` `from` `to` |
| `session_lost` | broker: children not carried (`reason` `gen`); Store: live panes closed or orphaned (`proc=store`, `reason` `fresh_restart`/`reconcile_failed`/`carry_unusable`, `panes`) | `reason` and `gen` or `proc` `panes` |
| `broker_vm_exit`, `broker_start`, `broker_stop` | broker lifecycle | `gen` `status` `role` / `pid` |
| `api_connect` | API connection accepted | `conns` (open count) |
| `api_denied` | API request refused before a handler ran | `method` `code` |
| `api_error` | API handler failed (`internal`/`timeout`/`backpressure`/`events_lost`) | `method` `code` `msg` |

`result=stale` means the reload was skipped because another source changed during the run.

Summary: `just live-log-summary [LOG ...] [--since ISO8601] [--json]`, which runs
`python3 live/scripts/log_summary.py`. It reports reloads, rollbacks, handoffs, test
runs, API connects/denials/errors and session losses. Exit status is 0 unless a log is unreadable.

The dogfooding exit criterion counts exactly: session_losses = `session_lost` lines
(broker fallback restore, Store closing or orphaning live panes) + unclean broker
restarts (a `broker_start` with no `broker_stop` since the previous `broker_start`, i.e.
the broker died and its children with it). `store_restarts` (`crash proc=store
action=restored`: the Store restarted from the mirror and kept the layout) are reported
separately and are not losses.

## Troubleshooting by log grep

```sh
L=${HERDR_LIVE_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-live/herdr-live.log}
grep 'herdr-event' "$L" | tail -20              # recent events
grep 'herdr-event compile_error' "$L" | tail -3 # why a save did nothing
grep 'herdr-event rollback' "$L" | tail -3      # what rolled back and why (reason, detail)
grep 'herdr-event guard_failure' "$L" | tail    # failures, and which batch they blamed
grep 'herdr-event sync' "$L"                    # modules loaded unattributed after a crash
grep -E 'herdr-event (purge_blocked|rejected)' "$L"
grep -E 'herdr-event (session_lost|crash|broker_handoff_failed)' "$L"
```

| symptom | check |
|---|---|
| save does nothing, no status change | the file is not under `apps/*/lib`; or it is a rolled-back source with unchanged content (edit it); or test-on-save blocked it (`herdr-event tests`); or the Watcher is disabled (Linux without `inotify-tools`, look for the warning in the log) |
| `r! compile` | `herdr-event compile_error` has file, line and message |
| `r blocked` / `purge_blocked` | a process still runs the old code of that module: `holders` names pid, name and function; fix the loop to call fully-qualified, or restart it |
| rolled back but you do not know why | `herdr-event rollback` `reason`/`detail`, and `guard_failure` `mfa`/`attributed` |
| edits missing after a crash | `herdr-event sync` (what was loaded), and `herdr-event broker_handoff` `kind=crash` |
| screen or layout reset | `herdr-event crash proc=store` and `session_lost` |
| tty left raw | broker restores it at exit; if a VM died early, run `stty sane` |
| screen frozen, VM still running (log has `crash proc=local_client action=gave_up`: the terminal client crashed past its restart limit and the VM runs headless) | from another terminal, `live/bin/herdr-live rollback` (undo the edit that broke the client), then `live/bin/herdr-live kernel-restart` (the new VM starts a fresh client on the tty) |
| `herdr-live: not running` from `rollback` or `test-on-save` | the API socket moves with the primary and is gone for a few ms during a graceful handoff; retry |

`live/bin/herdr-live status` prints the broker state (`primary_gen`, `primary_pid`,
`standby_ready`, `phase`, `handoffs`, `last_handoff_kind`).

## Verifying a change you made to the live system

- Focused tests: `cd live && mix test apps/<app>/test/<file>_test.exs`.
- Inside herdr-live, run `just live-test` and focused tests. The tty harness modes that
  launch `bin/herdr-live` (`herdr`, `herdr-stress`, `selfhost`) compile into and reload the
  `_build/dev` the running instance uses, so inside a herdr-live pane (detected by the
  inherited `HERDR_BROKER_SOCK`) they print `SKIP: <mode>: running inside herdr-live ...`
  and exit 0.
- Gate before committing: `just live-check` (format, credo --strict, dialyzer, cargo
  fmt/clippy, tests, launcher and attached smokes, tty harness), run from another
  worktree, or with the dogfood instance stopped (another terminal is not enough: the
  harness and smokes compile into the same `_build/dev` and selfhost writes into the
  watched tree). Do not run builds in parallel in one worktree. Inside a pane,
  `just live-test` and focused `mix test` are safe: the test VM drops the inherited
  broker and API env (`config/runtime.exs`).
- One instance per log file: two brokers writing one log produce false `broker_died`
  losses in `log_summary`.
- Self-hosted tty check: `python3 live/scripts/tty_harness.py selfhost` (drives herdr-live
  attached to a pty and edits it from inside; outside a herdr-live pane only).
- Reload metrics: `just live-bench-reload` (targets: render < 500 ms p95, view < 500 ms,
  ui_field < 1 s, view_loop <= 150 ms, closure rejected, pane_in_window reconciled).
  Other metrics: `just live-bench-handoff`, `just live-bench-glass`,
  `just live-bench-os-floor`; `live/bench/gate_round.sh <tag> [suite...]` runs the whole
  slice-1 table one suite after another, logging under
  `.superpowers/sdd/m6/runs/<os>-<tag>` unless `OUT` is set.
- After any change to the snapshot path (`Vt.encode_snapshot`/`restore`, the Snapshotter,
  the broker blob) or a libghostty-vt bump, re-run the kill -9 bench with 30 runs:
  `cd live && elixir bench/handoff/kill9.exs runs=30`. It exits 1 if any run has
  alive, answered, scrollback or htop below N/N or the warm p95 is >= 1000 ms. This is
  ADR 0001 item 4: vendored patch 0008 (`growable-restored-pages`) fixed scrollback loss
  after about 18 handoffs; keep or drop it deliberately (see
  `vendor/libghostty-vt.patches.md`), never by accident of a vendor bump.

## Known behaviour to expect

- Detach and quit are the same today: `prefix q` (ctrl-b q) stops herdr-live. There is no
  re-attach before M16.
- A graceful `kernel-restart` has no rollback after the new VM reports restored; a failure
  before that resumes the old VM (`handoff aborted`).
- A `kill -9` restores the screen as of the last snapshot (at most about 1 s old).
- A hang in `Actions.apply` or the Store is not budgeted; a Store `:kill` inside the
  20 ms mirror debounce loses the writes of that window.
