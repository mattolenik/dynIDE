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
Hangs inside `Actions.apply` or the Store have no budget (a known gap): a loop there
wedges that process until its callers time out.

A batch stays attributable until its modules have handled enough guarded calls (20
successes) and 5 s have passed; the ring is 8 batches deep. So a bad edit to a rarely
used feature is still blamed on the right batch when you finally use it, unless more
than 8 reloads happened since.

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
replies `ok <batch ids>`, `ok none` or `error ...`, through the local control socket of
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
  (`tests result=none`).
- The tests run in a separate `mix test` OS process (`MIX_ENV=test`, broker and control
  env removed, 120 s timeout) before compile. Only a pass loads.
- A failing or erroring run blocks the load and keeps the path blocked. Every later gated
  save re-runs the blocked paths' tests too; a pass loads everything and clears the set.
  A failing save leaves the source on disk but not loaded, so the running code stays old.
- The Watcher watches `apps/*/lib` only. After fixing a test, saving the test file alone
  does nothing: re-save a lib file.
- If a source under `apps/*/lib` changes while the tests run, the pass is not loaded
  (`tests result=stale`) and the newer save's batch gates it.
- The runtime setting does not survive a VM handoff; the new VM falls back to
  `HERDR_LIVE_TEST_ON_SAVE` or config. After `kernel-restart` or a crash, run
  `test-on-save on` again. Turning it off clears the blocked set (the next save loads
  whatever is on disk).
- Cost, measured on `view.ex` (n=5): save to "tests passed" median 861 ms, save to loaded
  median 981 ms (results/m7.md, Task 6 bench `bench/reload/test_gate_bench.exs`), against about 190 ms without the gate (results/m6-gate.md).

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
| `session_lost` | children not carried | `reason` `gen` |
| `broker_vm_exit`, `broker_start`, `broker_stop` | broker lifecycle | `gen` `status` `role` / `pid` |

`result=stale` means the reload was skipped because another source changed during the run.

Summary: `just live-log-summary [LOG ...] [--since ISO8601] [--json]`, which runs
`python3 live/scripts/log_summary.py`. It reports reloads, rollbacks, handoffs, test
runs and session losses (a `session_lost` line, or a store restored from the mirror,
which it counts as a layout reset). Exit status is 0 unless a log is unreadable.

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
| `herdr-live: not running` from `rollback` or `test-on-save` | the control socket moves with the primary and is gone for a few ms during a graceful handoff; retry |

`live/bin/herdr-live status` prints the broker state (`primary_gen`, `primary_pid`,
`standby_ready`, `phase`, `handoffs`, `last_handoff_kind`).

## Verifying a change you made to the live system

- Focused tests: `cd live && mix test apps/<app>/test/<file>_test.exs`.
- Gate before committing: `just live-check` (format, credo --strict, dialyzer, cargo
  fmt/clippy, tests, launcher and attached smokes, tty harness). Do not run builds in
  parallel in one worktree.
- Self-hosted tty check: `python3 live/scripts/tty_harness.py selfhost` (drives herdr-live
  attached to a pty and edits it from inside).
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
