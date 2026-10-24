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
└── M3 server core +  ────┼── (M3 runs against a fake kernel until M1/M2 land)
    terminal client
                          ▼
            ┌─────────────┴─────────────┐
            ▼                           ▼
   M4 live reload + rollback   M5 kernel restart under live children
            └─────────────┬─────────────┘
                          ▼
                     M6 slice-1 gate ──── go / no-go
                          ▼
                     M7 self-hosting loop          (from here on, herdr-live is built from inside herdr-live)
                          ▼
                 ┌────────┴────────┐
                 ▼                 ▼
          M8 persistence    M9 terminal fidelity
                 │                 ▼
                 │          M10 kitty graphics
                 └────────┬────────┘
                          ▼
      ┌───────────────────┼──────────────────┐
      ▼                   ▼                  ▼
M11 detection        M12 API + CLI      M13 chrome + UX
+ agent runtime           │
                          ▼
                    M14 plugins
                          ▼
            ┌─────────────┼─────────────┐
            ▼             ▼             ▼
     M15 GUI client  M16 remote    M17 long tail
                     attach
                          └──────┬──────┘
                                 ▼
                      M18 release + distribution
```

M4 and M5 are independent and can be owned by separate agents. After M7,
M8/M9 are independent, as are M11–M13 and M15–M17. The first release (M18)
does not wait for the GUI client. Windows is deferred; see the end of this
document.

---

## M0: project skeleton and tooling

**Goal.** A buildable, testable repo layout that holds the Elixir umbrella and
the Rust NIF crates side by side with the existing herdr tree, so later
milestones have somewhere to land and a CI gate from day one.

**Depends on.** Nothing.

**Scope.**
- Repo layout per design.md "Repo layout": Mix umbrella at `live/` with
  `apps/herdr_scene`, `apps/herdr_server`, `apps/herdr_term`; Rustler crates
  at `live/native/herdr_kernel` (links `crates/ghostty-vt`, `vendor/` in
  place) and `live/native/herdr_term`. The Rust `src/` tree stays as
  reference until the M6 gate passes, then is pruned in M7.
- Dependency rule enforced by a test: `herdr_server` and `herdr_term` depend
  on `herdr_scene`; neither depends on the other; `herdr_scene` depends on
  nothing.
- Umbrella with `consolidate_protocols: false` in dev, `-noshell -noinput`
  boot via a `herdr-live` launcher script, file logger, no stdout writes.
- Both Rustler crates compiling with `panic = "unwind"`, a hello NIF each,
  `crates/ghostty-vt` linked into `herdr_kernel` only.
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

**Design refs.** The split; Repo layout; State layout.

---

## M1: kernel — Vt and Pty

**Goal.** A shell can be spawned under a PTY, parsed by ghostty on a kernel
thread, and read back by the BEAM as packed rows and structured events,
without raw stream bytes ever crossing the boundary.

**Depends on.** M0.
**Parallel with.** M2, M3.

**Scope.**
- Packed cell format: fixed-width record spec in `herdr_scene`, documented
  with a byte diagram and shared test vectors that both Rust crates and the
  Elixir apps must pass.
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

**Design refs.** herdr_kernel: Native.Vt; herdr_kernel: Native.Pty; Rules.

---

## M2: terminal-client kernel — Tty and Blit

**Goal.** The `herdr_term` crate can take the host terminal into raw mode,
deliver its input bytes, and paint a full screen of packed rows with
diff-based ANSI output, restoring the terminal on every exit path.

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
- A throwaway `live-demo` that wires M1 + M2 directly (one pane, no server
  logic) to prove the pipe end to end.

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

**Design refs.** herdr_term: Native.Tty; herdr_term: Native.Blit.

---

## M3: server core and terminal client

**Goal.** A usable multi-pane multiplexer in Elixir: splits, focus, keybinds,
mouse, a status bar. The server emits scenes through the client protocol;
the terminal client, attached through that protocol even locally, renders
them. This is the milestone that bakes in the multi-frontend shape, so the
scene contract is designed here, not retrofitted.

**Depends on.** M0. Integrates with M1/M2 when they land; starts against a
fake kernel.
**Parallel with.** M1, M2.

**Scope.**
- `Kernel.Fake`: in-memory implementation of the `Native.*` contracts for
  tests and for developing M3 before M1/M2 exist. Keep it; it becomes the
  test double for everything after.
- `herdr_scene`: `%Scene{}`, `Scene.Pane`, `Scene.Overlay`, `Scene.Node`
  (chrome tree with roles, content, theme tokens; no glyphs or colours), the
  neutral input event vocabulary, validators, and golden fixtures. Published
  first; everything else in M3 consumes it.
- Client protocol: attach/detach, scene push, rows push for inline
  transports, notices. `Client.Supervisor` / `Client.Session` per attached
  client with `Client.State` (kind, size, cell px, requested viewports,
  hover). Local terminal client attaches through it, in-VM.
- Structs: `App.Session`, `App.Focus`, `App.Ui`, `Pane.State`,
  `Client.State`; `Map.merge` defaulting in every callback.
- `App.Store` with thin callbacks and a `safe_apply` placeholder (plain
  `try`; the real `Reload.Guard` arrives in M4).
- `App.Actions`: open/close/split/focus/resize pane, tabs, modes.
- `Client.Term.Input`: CSI u, legacy keys, SGR mouse, bracketed paste, focus
  events, terminal query reply windows → neutral events; parser state held
  in the GenServer; focused-pane fast path via `:persistent_term`.
- Keybind tables as `{M, F, A}`; default bindings mirroring herdr's.
- `View.compute/2`: per client; tile layout to pane rects plus a chrome tree
  with a `:status` node; port of `src/layout.rs` semantics (splits,
  navigation directions, borders expressed as scene data, not glyphs).
- `Client.Term.Render`: rasterize the chrome tree to cells, slice pane rows
  into screen rows, focused-pane highlight, cursor; overlay hooks for
  selection and links; event-driven with a minimum inter-frame interval,
  pending mark while in flight, full repaint on resize or restart.
- `Pane.Supervisor` / `Pane.Server` with resubscribe-on-restart; damage
  routed to every attached `Client.Session`.
- Scene snapshot test harness: dump the scene for a given state and client
  size as a golden fixture, independent of any renderer. These fixtures are
  what the GUI client (M15) is built against.

**Out of scope.** Reload, persistence, copy mode, sidebar, modals, detection,
any transport other than in-VM.

**Exit criteria.**
- Manual: open 15 panes via keybinds, run `htop` in several, `cat` a large
  file in one, type in another; no visible tearing.
- Manual: a second local terminal client (another terminal window) attached
  at a different size shows the same session correctly; typing in one is
  visible in the other.
- Benchmark harness (`just live-bench`) reports: keystroke → glass p95 idle
  (through the client protocol), frame cost at 1 vs 15 full panes at fixed
  geometry, scheduler stall max during `cat` 100MB in 15 panes. Numbers
  recorded; targets are judged at M6.
- ExUnit on `Kernel.Fake`: layout, focus navigation, key parsing property
  tests (round-trip against `encode_key` vectors), scene golden fixtures,
  rasterized output for a known scene.
- Architecture test: no module in `herdr_server` references `Client.Term.*`
  or `Native.Tty`/`Native.Blit`; no module in `herdr_term` references
  `App.*` or `Native.Vt`/`Native.Pty`.

**Design refs.** Scene contract; Client protocol; Supervision trees; State
layout; Rendering pipeline; Input pipeline.

---

## M4: live reload and rollback

**Goal.** Saving a file in the brain is reflected in the running IDE in under a
second, and a bad edit rolls back automatically with state intact.

**Depends on.** M3.

**Scope.**
- `Reload.Watcher`: filesystem events on `live/apps/*/lib/**`, 50ms
  debounce; reload spans every umbrella app.
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
- ETS mirrors for `App.*`, `Pane.State`, and `Client.State`, owned by
  `Native.Keeper` with `heir`, debounced, per sub-struct / per pane / per
  client; restart-from-ETS path pushes a full scene to affected clients.
- `herdr-live rollback [n]` command and status-line notices for compile
  error, loaded, rolled back, rejected.

**Out of scope.** NIF reload (never), handoff (M5).

**Exit criteria.**
- Each row of the design.md slice-1 metrics table that concerns reload has
  a reproducible script under `live/bench/reload/` and a recorded number:
  edit `Client.Term.Render`; edit `View.compute` (chrome tree change); add a
  field to `App.Ui`; add a field to `App.Session` (fan-out count recorded);
  add a field to a `Scene` struct (fan-out across apps recorded); infinite
  loop in `View.compute`; closure placed in state then second reload;
  rollback after a pane spawned in the window; reload while `cat` runs in
  15 panes.
- ExUnit: `Reload.Guard` unit tests for each failure class and for
  attribution.

**Design refs.** Hot reload (all subsections).

---

## M5: kernel restart under live children

**Goal.** A kernel change or a VM crash is a sub-second restart with every
PTY and child process preserved, so "never lose terminals" holds even when
the brain cannot help.

**Depends on.** M1, M2, M3 (a session to preserve).
**Parallel with.** M4. In the gate because it, not supervision, is what
makes "never lose terminals" true.

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
  recorded in `results/m5.md`.
- Kernel rebuild + `kernel-restart` during active typing loses no keystrokes
  after the restart completes.

**Design refs.** What hot reload does not cover.

---

## M6: slice-1 gate

**Goal.** Decide, with numbers, whether the architecture holds before the
breadth work is paid for.

**Depends on.** M1, M2, M3, M4, M5.

**Scope.**
- Run the full slice-1 metrics table from design.md on Linux and macOS,
  three runs each, recorded in `results/m6-gate.md` with hardware and
  commit.
- For every miss: root cause and one of (a) a bounded fix inside the slice,
  (b) an accepted architecture change written back into design.md, or
  (c) a no-go recommendation.
- Include the M5 kernel-restart metric (`kill -9` with 15 shells, children
  alive, under one second p95) and the second-client metric in the table.
- Specifically test the composition-cost fallback question: if 15-pane full
  repaints miss, prototype the policy-free compose-helper NIF and re-measure.
- Decision record (ADR): go / no-go / go-with-changes.

**Exit criteria.**
- ADR committed. If go: design.md updated for any changes, and M7 unblocked.

**Design refs.** Slices and go/no-go.

---

## M7: self-hosting loop

**Goal.** herdr-live is developed from inside herdr-live. An agent in one pane
edits the source; the IDE around it reloads; the human watches and steers.

**Depends on.** M6 (go).

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

## M8: persistence and session restore

**Goal.** Layout, tabs, workspaces, and per-pane metadata survive a full
stop/start; scrollback restore follows a stated policy.

**Depends on.** M7.
**Parallel with.** M9.

**Scope.**
- `Persist.Writer`: debounced snapshots of `App.Session`/`App.Ui`/pane
  metadata to disk; schema versioning and migration hooks.
- Startup restore: recreate panes (new shells in the recorded cwd), restore
  layout and focus.
- Scrollback persistence policy decision (none / last N rows / full) and
  implementation.
- Interaction with M5: handoff state takes precedence when present.

**Exit criteria.**
- Stop, start, identical layout and cwds; property test that snapshot →
  restore → snapshot is a fixed point.

---

## M9: terminal fidelity

**Goal.** Everything a terminal user expects of a pane works: scrolling,
selection and copy across pane boundaries, links, paste, queries, OSC side
channels.

**Depends on.** M7.
**Parallel with.** M8.

**Scope.**
- Scrollback scrolling via `scroll_to`, scrollbar as a scene overlay drawn
  by `Client.Term.Render`, mouse wheel, keyboard.
- Copy mode and selection: character/word/line, across pane boundaries,
  expressed as semantic overlays in the scene; clipboard via OSC 52 to the
  host and system clipboard where available.
- Hover links and click-to-open with modifiers.
- OSC trackers moved to Elixir from kernel splitter events: title, pwd,
  default colors and theme queries, kitty keyboard state, XTGETTCAP,
  DECSCUSR.
- Bracketed paste with size limits; focus in/out passthrough; bell.
- Terminal query roundtrips (DA, DSR, color) between host, server, and child.
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
- `graphics_placements` carried in `Scene.Pane`; `Client.Term.Render` clips,
  orders against chrome, and emits placement commands alongside cells
  through `Native.Blit`.
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

**Depends on.** M7.
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

**Depends on.** M7.
**Parallel with.** M11, M12.

**Scope.**
- Sidebar with pane/agent tokens; tabs and workspaces; drag-to-resize
  splits; modal framework reused for settings, confirmations, onboarding.
  Every one of these is a chrome-tree node type in `herdr_scene` plus a
  rasterizer in `Client.Term.Render`; nothing is drawn directly.
- `:chrome` input events: hit-testing chrome nodes to paths on the client,
  actions resolved on the server.
- Theme system as named tokens in the scene; terminal-theme detection and
  token resolution in the terminal client.
- Keybind editing UI and config file format (TOML or JSONC as herdr).
- Notifications and sound hooks.
- Dev-only HTML scene renderer (`mix herdr.scene.html`): a few hundred lines
  that render a scene fixture to a static page. It exists to prove a second
  consumer can draw every node type without terminal assumptions, before
  M15 commits to one.

**Exit criteria.**
- Side-by-side manual review against herdr for each screen; recorded gaps.
- Every chrome node type has a golden scene fixture and renders in both the
  terminal client and the HTML renderer.

---

## M14: plugins

**Goal.** herdr's plugin model (installation, commands, link handlers, pane
messaging) available to herdr-live plugins, unchanged: plugins stay external
processes driven through the manifest, environment, and socket API.

**Depends on.** M12, M13.

**Scope.**
- Plugin discovery and installation paths; plugin command execution; link
  handler protocol with click modifiers; pane-to-pane messaging.
- Out of scope: BEAM plugins (modules loaded from plugin directories into
  the VM). Deferred by the human on 2026-10-24; revisit only with a new
  milestone.

**Exit criteria.**
- Two of herdr's existing plugins installed and working unmodified.

---

## M15: GUI client

**Goal.** A second frontend consuming the same scenes and emitting the same
events, proving the server is frontend-neutral and giving herdr-live a
windowed UI.

**Depends on.** M13 (every chrome node type exists and has fixtures), M16
(a socket transport, since the GUI may run out of process).
**Parallel with.** M17.

**Scope.**
- Technology decision (ADR): LiveView in a webview (Tauri/wry) is the
  leading candidate because the client stays in Elixir and hot reload plus
  the Guard apply to it. Alternatives recorded with the live-editing cost.
- `apps/herdr_gui`: attaches with `kind: :gui`; reports cell size from its
  font metrics; renders pane rows to a canvas from packed cells; draws the
  chrome tree as widgets; renders overlays natively; emits neutral events
  including `px` coordinates.
- Kitty graphics placements drawn as images.
- Reload notices and rollback surfaced in the GUI as in the terminal.
- Packaging for the GUI alongside the server release.

**Exit criteria.**
- The GUI and a terminal client attached to the same session simultaneously,
  both correct, typing in either visible in both.
- Every M13 chrome fixture renders in the GUI with no change to
  `herdr_server`. Any server change needed to make the GUI work is a defect
  in the scene contract and is recorded as such.
- Live edit of a GUI render module reflected in the running window in under
  a second.

---

## M16: remote attach

**Goal.** Attach to a herdr-live server from another machine or terminal over
SSH. Because the terminal client already speaks the client protocol, this is
a transport and a reconnect story, not a rendering one.

**Depends on.** M12 (API surface for session discovery and auth).
**Parallel with.** M15, M17.

**Scope.**
- Socket transport for the client protocol: length-prefixed ETF over a unix
  socket forwarded through SSH, or TLS distribution; never epmd exposed.
- `{:inline, rows}` scenes for socket clients; row push batching.
- Reconnect semantics; client-local failure notices that do not disconnect
  other clients; handoff-aware re-attach during kernel restart.
- `herdr-live attach <host>` CLI.

**Exit criteria.**
- Remote and local clients of different sizes attached simultaneously;
  typing in one is visible in the other; disconnect/reconnect preserves the
  session; kernel restart on the server keeps the remote client attached.

---

## M17: long tail

**Goal.** The remaining herdr features users rely on.

**Depends on.** M13.
**Parallel with.** M15, M16.

**Scope.** Inventory from herdr `src/`, each as its own task: git worktree
management, agent resume, product announcements and release notes display,
copy-mode search, popup sizing, metadata tokens, sound, update notifications
for the new channel, anything found missing during M7 dogfooding.

**Exit criteria.** Inventory closed with each item done or explicitly
dropped with a reason.

---

## M18: release and distribution

**Goal.** Installable builds and an update channel.

**Depends on.** M16, M17. The GUI client (M15) ships when ready; the first
release is terminal-only.

**Scope.**
- Self-contained release per platform (Mix release with bundled ERTS plus
  both NIF `.so`s), single-command install.
- Update command and channel manifest; kernel restart (M5) used for
  in-place updates so sessions survive.
- Homebrew/Nix packaging; docs site content for herdr-live.
- Signing and notarization where required.

**Exit criteria.** Fresh-machine install on each platform from the published
artifact; in-place update of a running session with no session loss.

---

## Deferred: Windows

Not scheduled. When it is picked up it needs: a ConPTY backend for
`Native.Pty`, a console backend for `Native.Tty` (VT input mode, resize
events, the Windows Terminal cursor-anchor quirk from `render_ansi.rs`), a
kernel-restart story without SCM_RIGHTS (handle duplication into the new
process, or a documented fallback to disk restore), packaging with the
app-local ConPTY runtime, and a Windows CI job. Nothing before M18 should
make it harder: keep platform code behind the `Native.*` contracts.

---

## Suggested first wave

Four agents can start as soon as M0 lands:

| agent | milestone | note |
|---|---|---|
| A | M1 | `herdr_kernel` Vt + Pty; owns the packed cell spec in `herdr_scene` and must publish it first |
| B | M2 | `herdr_term` Tty + Blit; consumes the packed cell spec |
| C | M3 | server core and terminal client against `Kernel.Fake`; owns the scene and event contracts in `herdr_scene` and publishes them before building on them; swaps to real NIFs as A/B land |
| D | M4 prep | `Reload.Compiler` and `Reload.Guard` can be built and unit-tested against toy modules before M3 exists |

`herdr_scene` has two early owners (A for packed cells, C for scene and
events) in disjoint files; C arbitrates conflicts.

Second wave, as soon as M1 and M2 land: agent E on M5 (kernel restart), in
parallel with D finishing M4. M6 is a single-owner gate. After M7, the
parallel groups in the dependency graph apply.
