# herdr-live: milestones

Companion to [design.md](design.md). Each milestone below is sized to be
decomposed into tasks that one agent (with subagents) can plan and implement
independently. Scope bullets are the seed list for those tasks; exit criteria
are what the milestone owner must demonstrate, not just claim.

Conventions:

- A milestone is done when every exit criterion is met and recorded in
  `docs/herdr-live/results/<milestone>.md` with the numbers, environment, and
  commit hash.
- Design section references point at headings in `design.md`.
- "Parallel with" names milestones whose tasks can run concurrently given a
  stub or contract; "Depends on" names hard prerequisites.

## Dependency graph

```
M0 skeleton
├── M1 kernel: vt + pty ──┐
├── M2 kernel: tty + blit ┤
└── M3 brain core ────────┼── (M3 runs against a fake kernel until M1/M2 land)
                          ▼
                     M4 live reload + rollback
                          ▼
                     M5 slice-1 gate ──── go / no-go
                          ▼
                     M6 self-hosting loop          (from here on, herdr-live is built from inside herdr-live)
                          ▼
            ┌─────────────┼─────────────────┐
            ▼             ▼                 ▼
    M7 kernel restart  M8 persistence   M9 terminal fidelity
    under live children                     │
            │                               ▼
            │                        M10 kitty graphics
            └──────────┬────────────────────┘
                       ▼
      ┌────────────────┼──────────────────┐
      ▼                ▼                  ▼
M11 detection     M12 API + CLI      M13 chrome + UX
+ agent runtime        │
                       ▼
                 M14 plugins
                       ▼
      ┌────────────────┼────────────────┐
      ▼                ▼                ▼
M15 remote attach  M16 long tail    M17 windows
                       ▼
                 M18 release + distribution
```

M7–M10 are independent of each other and can be owned by separate agents at
the same time. Likewise M11–M13, and M15–M17.

---

## M0: project skeleton and tooling

**Goal.** A buildable, testable repo layout that holds the Elixir brain and the
Rust kernel side by side with the existing herdr tree, so later milestones
have somewhere to land and a CI gate from day one.

**Depends on.** Nothing.

**Scope.**
- Decide and record repo layout: Elixir app at `live/` with the Rustler crate
  at `live/native/herdr_kernel`, depending on `crates/ghostty-vt` and
  `vendor/` in place. The Rust `src/` tree stays as reference until the M5
  gate passes, then is pruned in M6.
- Mix project with `consolidate_protocols: false` in dev, `-noshell -noinput`
  boot via a `herdr-live` launcher script, file logger, no stdout writes.
- Rustler crate compiling with `panic = "unwind"`, a hello NIF, and
  `crates/ghostty-vt` linked.
- `just` recipes: `live-test`, `live-check` (format, credo, dialyzer, cargo
  clippy, ExUnit, cargo test), `live-run`, `live-bench`.
- CI job running `just live-check` on Linux and macOS.
- Rewrite `CLAUDE.md` for the fork: remove maintainer, release, and docs
  sections that no longer apply; add the live-edit rules from
  design.md "State layout" (no local funs in state, MFA keybinds, struct
  split, `safe_apply` boundary) so agents editing the IDE follow them.
- ADR template and `docs/herdr-live/results/` directory.

**Out of scope.** Any real NIF behaviour; any UI.

**Exit criteria.**
- `just live-check` green on a clean clone on Linux and macOS.
- `herdr-live` launcher boots the VM headless, logs to file, exits cleanly on
  SIGTERM with the tty untouched.
- `CLAUDE.md` reviewed against design.md rules.

**Design refs.** The split; State layout.

---

## M1: kernel — Vt and Pty

**Goal.** A shell can be spawned under a PTY, parsed by ghostty on a kernel
thread, and read back by the BEAM as packed rows and structured events,
without raw stream bytes ever crossing the boundary.

**Depends on.** M0.
**Parallel with.** M2, M3.

**Scope.**
- Packed cell format: fixed-width record spec, documented with a byte diagram
  and a shared test vector used by both Rust and Elixir tests.
- `Native.Vt`: `new`, `resize`, `dirty_rows`, `full_rows`, `read_text`
  (dirty-CPU), `scrollbar`, `scroll_to`, `mode`, `kitty_keyboard_flags`,
  `link_at`, `graphics_placements`.
- Per-pane `RenderState` snapshot refreshed under a short lock between
  chunks; BEAM reads iterate the snapshot outside the lock; `try_lock` with
  `{:stale, _}` for scalar accessors.
- `Native.Vt.encode_key`, `encode_mouse`, `encode_focus` over ghostty's
  encoders using live terminal modes.
- `Native.Pty`: `spawn`, `write` (bounded queue, `{:error, :backpressure}`),
  `resize`, `kill`, `subscribe`, `set_hidden`.
- Reader thread: PTY read, OSC/DCS splitter, `ghostty_terminal_write`,
  snapshot refresh, damage coalescing (≤ 1 per 4ms while flowing, immediate
  on quiescence), hidden-pane suppression.
- Writer thread: single ordered queue shared by BEAM writes and ghostty
  `WritePtyCallback` responses.
- Events: `{:damage, id, gen}`, `{:exit, id, status}`, `{:osc, id, code,
  payload}` with OSC 52 cap, `{:dcs, ...}`, `{:bell, id}`, `{:title, ...}`,
  `{:pwd, ...}`.
- `enif_monitor_process` on subscribers; resubscribe triggers full damage.
- `catch_unwind` in every kernel thread loop, reporting `{:exit, id,
  {:panic, reason}}`.
- Child reaping strategy that coexists with erts; tested.
- `Native.Keeper` GenServer owning all resources and the pane-id table.

**Out of scope.** Host tty, blitting, ConPTY.

**Exit criteria.**
- ExUnit: spawn `sh`, write `echo hi`, receive damage, `dirty_rows` contains
  `hi`; exit event on `exit`.
- ExUnit: `cat` of a 100MB file in one pane; `mode/2` called from a normal
  scheduler in a loop never blocks > 1ms (measured with
  `:erlang.monotonic_time`).
- ExUnit: subscriber process killed and restarted receives full damage.
- Rust test: induced panic in the reader thread produces the exit event and
  the VM stays up.
- Rust + ExUnit: packed-cell test vector round-trips.

**Design refs.** Native.Vt; Native.Pty; Rules.

---

## M2: kernel — Tty and Blit

**Goal.** The kernel can take the host terminal into raw mode, deliver its
input bytes, and paint a full screen of packed rows with diff-based ANSI
output, restoring the terminal on every exit path.

**Depends on.** M0.
**Parallel with.** M1, M3.

**Scope.**
- `Native.Tty`: `open`, `restore` (idempotent, also from the resource
  destructor), `size`, `subscribe`, `write` (bounded host-tty writer thread,
  frame drop when behind), `suspend`.
- SIGWINCH via `:os.set_signal` on the BEAM side; SIGCONT re-raw and
  `{:tty_resumed}`.
- `Native.Blit.frame`: port of `BlitEncoder` (synchronized output, cursor
  hide/restore, DECSCUSR, minimal cursor movement) taking packed rows; retained
  last frame; full-repaint path.
- Blit runs on a dedicated kernel thread, never a dirty scheduler.
- Kitty keyboard protocol query at open; result exposed to the BEAM.
- A throwaway `live-demo` that wires M1 + M2 directly (one pane, no brain) to
  prove the pipe end to end.

**Out of scope.** Composition, overlays, multiple panes.

**Exit criteria.**
- `live-demo` shows a working single shell in the host terminal; Ctrl-Z
  suspends and `fg` resumes with the screen restored; resizing the window
  repaints; `kill -9` of the VM leaves the terminal usable (destructor
  restore proven by a test that skips `terminate/2`).
- Rust test: frame diff against a retained frame emits only changed cells for
  a one-cell change.
- Rust test: blocked host tty (reader stopped) does not block the caller of
  `write`; frames are dropped, not queued unbounded.

**Design refs.** Native.Tty; Native.Blit.

---

## M3: brain core — state, input, layout, render

**Goal.** A usable multi-pane multiplexer in Elixir: splits, focus, keybinds,
mouse, a status bar, composed in the brain from packed rows.

**Depends on.** M0. Integrates with M1/M2 when they land; starts against a
fake kernel.
**Parallel with.** M1, M2.

**Scope.**
- `Kernel.Fake`: in-memory implementation of the `Native.*` contracts for
  tests and for developing M3 before M1/M2 exist. Keep it; it becomes the
  test double for everything after.
- Structs: `App.Session`, `App.Focus`, `App.Ui`, `Pane.State`; `Map.merge`
  defaulting in every callback.
- `App.Store` with thin callbacks and a `safe_apply` placeholder (plain
  `try`; the real `Reload.Guard` arrives in M4).
- `App.Actions`: open/close/split/focus/resize pane, tabs, modes.
- `Input.Parse`: CSI u, legacy keys, SGR mouse, bracketed paste, focus
  events, terminal query reply windows; parser state held in `Input.Reader`.
- `Input.Reader` with the focused-pane fast path via `:persistent_term`.
- Keybind tables as `{M, F, A}`; default bindings mirroring herdr's.
- `View.compute`: tile layout to rects per pane plus chrome specs; port of
  `src/layout.rs` semantics (splits, navigation directions, borders).
- `Render.compose`: slice pane rows into screen rows, borders, focused-pane
  highlight, status bar, cursor; placeholder overlay hooks for selection and
  links.
- `Render.Loop`: event-driven with minimum inter-frame interval, pending
  mark while in flight, full-damage on resize or restart.
- `Pane.Supervisor` / `Pane.Server` with resubscribe-on-restart.

**Out of scope.** Reload, persistence, copy mode, sidebar, modals, detection.

**Exit criteria.**
- Manual: open 15 panes via keybinds, run `htop` in several, `cat` a large
  file in one, type in another; no visible tearing.
- Benchmark harness (`just live-bench`) reports: keystroke → glass p95 idle,
  frame cost at 1 vs 15 full panes at fixed geometry, scheduler stall max
  during `cat` 100MB in 15 panes. Numbers recorded; targets are judged at M5.
- ExUnit on `Kernel.Fake`: layout, focus navigation, key parsing property
  tests (round-trip against `encode_key` vectors), compose output for a
  known frame.

**Design refs.** Supervision tree; State layout; Rendering pipeline; Input
pipeline.

---

## M4: live reload and rollback

**Goal.** Saving a file in the brain is reflected in the running IDE in under a
second, and a bad edit rolls back automatically with state intact.

**Depends on.** M3.

**Scope.**
- `Reload.Watcher`: filesystem events on `live/lib/**`, 50ms debounce.
- `Reload.Compiler`: drives Mix's incremental compiler in a Task, returns
  the recompiled module set (fan-out), surfaces compile errors.
- Batch record `{batch_id, modules, previous_beams, state_at_load}` in an
  N-deep ring.
- `:code.soft_purge` first; diagnostics naming the offending process on
  failure; hard purge only for an allowlist.
- `Reload.Guard.run/4`: catches `raise`/`throw`/`exit`, deadline via linked
  task, attributes failures to a batch from the stack trace, triggers
  synchronous rollback, re-applies the event.
- Replace the M3 `safe_apply` placeholder in every thin GenServer.
- Rollback policy: code first (state kept); on repeat failure restore
  `state_at_load` and **reconcile** against `Native.Keeper`'s pane table.
- Exercise-keyed rollback window with wall-clock floor.
- Dev-time local-fun scan of new state in `Reload.Guard`; rejects with a
  message naming the module and key.
- ETS mirrors for `App.*` and `Pane.State`, owned by `Native.Keeper` with
  `heir`, debounced, per sub-struct / per pane; restart-from-ETS path.
- `herdr-live rollback [n]` command and status-line notices for compile
  error, loaded, rolled back, rejected.

**Out of scope.** NIF reload (never), handoff (M7).

**Exit criteria.**
- Each row of the design.md slice-1 metrics table that concerns reload has
  a reproducible script under `live/bench/reload/` and a recorded number:
  edit `Render.compose`; add a field to `App.Ui`; add a field to
  `App.Session` (fan-out count recorded); infinite loop in `View.compute`;
  closure placed in state then second reload; rollback after a pane spawned
  in the window; reload while `cat` runs in 15 panes.
- ExUnit: `Reload.Guard` unit tests for each failure class and for
  attribution.

**Design refs.** Hot reload (all subsections).

---

## M5: slice-1 gate

**Goal.** Decide, with numbers, whether the architecture holds before the
breadth work is paid for.

**Depends on.** M1, M2, M3, M4.

**Scope.**
- Run the full slice-1 metrics table from design.md on Linux and macOS,
  three runs each, recorded in `results/m5-gate.md` with hardware and
  commit.
- For every miss: root cause and one of (a) a bounded fix inside the slice,
  (b) an accepted architecture change written back into design.md, or
  (c) a no-go recommendation.
- Specifically test the composition-cost fallback question: if 15-pane full
  repaints miss, prototype the policy-free compose-helper NIF and re-measure.
- Decision record (ADR): go / no-go / go-with-changes.

**Exit criteria.**
- ADR committed. If go: design.md updated for any changes, and M6 unblocked.

**Design refs.** Slices and go/no-go.

---

## M6: self-hosting loop

**Goal.** herdr-live is developed from inside herdr-live. An agent in one pane
edits the source; the IDE around it reloads; the human watches and steers.

**Depends on.** M5 (go).

**Scope.**
- `herdr-live` runs standalone as the daily driver for the team working on
  it (minimum: panes, splits, status bar, reload notices, rollback command).
- Reload status surfaced in chrome: last batch, fan-out count, compile
  errors inline, rollback events with reason.
- Test-on-save option: run the changed module's ExUnit tests before load;
  show pass/fail in the status line; configurable because it adds latency.
- Agent-facing docs: `CLAUDE.md` rules for live-safe edits, how to read
  reload/rollback notices, how to run the metrics scripts; a
  `docs/herdr-live/editing-live.md` guide.
- Prune the Rust `src/` tree and everything only it used (keep
  `crates/ghostty-vt`, `vendor/`, and files the kernel still needs). Record
  what was removed so it can be consulted from git history.
- Crash and reload telemetry to the log file for post-hoc debugging of a
  session.

**Out of scope.** Feature parity.

**Exit criteria.**
- One week of the team using herdr-live as the primary terminal for
  herdr-live work, with a log of reload counts, rollbacks, and any session
  loss. Zero session losses attributable to brain edits.

**Design refs.** Goal; Hot reload.

---

## M7: kernel restart under live children

**Goal.** A kernel change or a VM crash is a sub-second restart with every
PTY and child process preserved, so "never lose terminals" holds even when
the brain cannot help.

**Depends on.** M6.
**Parallel with.** M8, M9.

**Scope.**
- Port SCM_RIGHTS fd transfer from `src/server/handoff.rs` into the kernel.
- `HandoffState` per pane (child pid, size, keyboard flags, input state,
  title, serialized scrollback or ANSI history) over a unix socket.
- Supervisor process outside the VM (tiny Rust or shell launcher) that
  starts the new VM, brokers the handoff, and only then lets the old VM
  exit; falls back to disk restore if handoff fails.
- `herdr-live kernel-restart` command used after kernel builds.
- Crash path: a dying VM (where possible) and the launcher's watchdog both
  initiate handoff; `kill -9` relies on the launcher holding duplicate fds.

**Out of scope.** Windows.

**Exit criteria.**
- `kill -9` of the VM with 15 shells running (some mid-`htop`) → new VM
  attached, all children alive, scrollback restored, under one second p95,
  recorded in `results/m7.md`.
- Kernel rebuild + `kernel-restart` during active typing loses no keystrokes
  after the restart completes.

**Design refs.** What hot reload does not cover.

---

## M8: persistence and session restore

**Goal.** Layout, tabs, workspaces, and per-pane metadata survive a full
stop/start; scrollback restore follows a stated policy.

**Depends on.** M6.
**Parallel with.** M7, M9.

**Scope.**
- `Persist.Writer`: debounced snapshots of `App.Session`/`App.Ui`/pane
  metadata to disk; schema versioning and migration hooks.
- Startup restore: recreate panes (new shells in the recorded cwd), restore
  layout and focus.
- Scrollback persistence policy decision (none / last N rows / full) and
  implementation.
- Interaction with M7: handoff state takes precedence when present.

**Exit criteria.**
- Stop, start, identical layout and cwds; property test that snapshot →
  restore → snapshot is a fixed point.

---

## M9: terminal fidelity

**Goal.** Everything a terminal user expects of a pane works: scrolling,
selection and copy across pane boundaries, links, paste, queries, OSC side
channels.

**Depends on.** M6.
**Parallel with.** M7, M8.

**Scope.**
- Scrollback scrolling via `scroll_to`, scrollbar overlay in
  `Render.compose`, mouse wheel, keyboard.
- Copy mode and selection: character/word/line, across pane boundaries,
  clipboard via OSC 52 to the host and system clipboard where available.
- Hover links and click-to-open with modifiers.
- OSC trackers moved to Elixir from kernel splitter events: title, pwd,
  default colors and theme queries, kitty keyboard state, XTGETTCAP,
  DECSCUSR.
- Bracketed paste with size limits; focus in/out passthrough; bell.
- Terminal query roundtrips (DA, DSR, color) between host, brain, and child.
- Resize reflow behaviour verified against herdr's.

**Exit criteria.**
- Scripted checks under `live/bench/fidelity/` plus a manual checklist
  recorded with pass/fail per item against herdr behaviour.

---

## M10: kitty graphics in composed frames

**Goal.** Images rendered by children appear in the right place, clipped to
pane rects, across splits and scrolling.

**Depends on.** M9.

**Scope.**
- `graphics_placements` consumption in `Render.compose`; clipping; z-order
  with chrome; placement emission alongside cells in `Native.Blit`.
- Image source forwarding and file-backed transmission as herdr does today.
- Cleanup on pane close and on reload.

**Exit criteria.**
- `kitten icat` and an image-heavy TUI in two split panes render correctly
  through resize and scroll; screenshots compared against herdr.

---

## M11: agent detection and agent runtime

**Goal.** herdr-live knows what the agent in each pane is doing (idle, working,
blocked), using herdr's manifests, and exposes it the same way.

**Depends on.** M9.
**Parallel with.** M12, M13.

**Scope.**
- Manifest loader for `src/detect/manifests/*.toml` (or their new home);
  regexes vetted for PCRE; `match_limit`; the kernel fallback if needed.
- Detection engine: regions, AND/OR/NOT gates, priority, skip states, source
  precedence; engine tests with synthetic manifests (not CLI screenshots).
- Bottom-buffer snapshot polling with an explicit per-pane budget.
- Agent OSC state tracker from kernel events.
- Manifest hot reload (trivial under the BEAM, but keep the command).
- `agent read` / `agent explain` equivalents for the CLI (M12).

**Exit criteria.**
- Live smoke test with at least two real agents through idle / working /
  blocked transitions, recorded with CLI versions and observed signals.

---

## M12: API and CLI

**Goal.** A JSON socket API and CLI equivalent to herdr's for panes, agents,
workspaces, and events, so automation and agents can drive herdr-live.

**Depends on.** M6.
**Parallel with.** M11, M13.

**Scope.**
- `Api.Listener` over a unix socket; JSON request/response and event
  subscriptions; schema generation for docs.
- CLI (`herdr-live ...`) covering herdr's current command surface as an
  inventory, prioritized by what the self-hosting loop and agents use.
- Classification rule from herdr's runtime/client guardrail carried over:
  shared runtime facts in the API, presentation state not.

**Exit criteria.**
- API conformance tests; CLI used by the agent in the self-hosting loop to
  open panes and read agent state.

---

## M13: chrome and UX parity

**Goal.** The mouse-first TUI herdr users know: sidebar, tabs, workspaces,
modals, settings, onboarding, consistent affordances.

**Depends on.** M6.
**Parallel with.** M11, M12.

**Scope.**
- Sidebar with pane/agent tokens; tabs and workspaces; drag-to-resize
  splits; modal framework reused for settings, confirmations, onboarding.
- Theme system and terminal-theme detection.
- Keybind editing UI and config file format (TOML or JSONC as herdr).
- Notifications and sound hooks.

**Exit criteria.**
- Side-by-side manual review against herdr for each screen; recorded gaps.

---

## M14: plugins

**Goal.** herdr's plugin model (installation, commands, link handlers, pane
messaging) available to herdr-live plugins, with the BEAM's reload applying to
plugins too.

**Depends on.** M12, M13.

**Scope.**
- Plugin discovery and installation paths; plugin command execution; link
  handler protocol with click modifiers; pane-to-pane messaging.
- Decide the plugin language story: BEAM modules loaded from plugin
  directories (hot-reloadable), plus the existing external-process protocol
  for non-BEAM plugins.

**Exit criteria.**
- Two of herdr's existing plugins ported or bridged and working.

---

## M15: remote attach and multi-client

**Goal.** Attach to a herdr-live server from another machine or terminal with
a client of a different size, over SSH, using the same packed-row render path.

**Depends on.** M13.
**Parallel with.** M16, M17.

**Scope.**
- Client node: `Tty.Owner`, `Input.Reader`, `Render.Loop`, `Native.Blit`
  local; rows from the server composed per client size and cell px.
- Transport: plain socket over SSH or TLS distribution; never epmd exposed.
- Per-client state (viewport, selection) in the client; shared session
  state on the server.
- Reconnect semantics; client-local failure notices that do not disconnect
  other clients.

**Exit criteria.**
- Two clients of different sizes attached simultaneously; typing in one is
  visible in the other; disconnect/reconnect preserves the session.

---

## M16: long tail

**Goal.** The remaining herdr features users rely on.

**Depends on.** M13.
**Parallel with.** M15, M17.

**Scope.** Inventory from herdr `src/`, each as its own task: git worktree
management, agent resume, product announcements and release notes display,
copy-mode search, popup sizing, metadata tokens, sound, update notifications
for the new channel, anything found missing during M6 dogfooding.

**Exit criteria.** Inventory closed with each item done or explicitly
dropped with a reason.

---

## M17: Windows

**Goal.** herdr-live runs natively on Windows.

**Depends on.** M7 (kernel restart story must be settled first; SCM_RIGHTS
does not exist there).
**Parallel with.** M15, M16.

**Scope.**
- `Native.Pty` ConPTY backend; `Native.Tty` console backend (VT input mode,
  resize events, the Windows Terminal cursor-anchor quirk from
  `render_ansi.rs`).
- Kernel restart on Windows: handle duplication into the new process in
  place of fd passing, or documented fallback to disk restore.
- Packaging with the app-local ConPTY runtime.
- CI on Windows for `just live-check`.

**Exit criteria.** Slice-1 metrics table rerun on Windows and recorded; a
Windows user on the team runs it daily for a week.

---

## M18: release and distribution

**Goal.** Installable builds and an update channel.

**Depends on.** M15, M16 (M17 for the Windows asset).

**Scope.**
- Self-contained release per platform (Mix release with bundled ERTS plus
  the kernel `.so`/`.dll`), single-command install.
- Update command and channel manifest; kernel restart (M7) used for
  in-place updates so sessions survive.
- Homebrew/Nix packaging; docs site content for herdr-live.
- Signing and notarization where required.

**Exit criteria.** Fresh-machine install on each platform from the published
artifact; in-place update of a running session with no session loss.

---

## Suggested first wave

Four agents can start as soon as M0 lands:

| agent | milestone | note |
|---|---|---|
| A | M1 | kernel Vt + Pty; owns the packed cell spec and must publish it first |
| B | M2 | kernel Tty + Blit; consumes the packed cell spec |
| C | M3 | brain core against `Kernel.Fake`; swaps to real NIFs as A/B land |
| D | M4 prep | `Reload.Compiler` and `Reload.Guard` can be built and unit-tested against toy modules before M3 exists |

M5 is a single-owner gate. After M6, the parallel groups in the dependency
graph apply.
