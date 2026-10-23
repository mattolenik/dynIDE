# herdr-live: design sketch

Status: exploratory, revision 2 after critical review. This is a fork
direction, not a change to herdr.

## Goal

An agent edits the IDE's source while you are using it, and the running IDE
reflects each change in under a second without losing terminals, scrollback,
or layout. A bad edit must never take the IDE down.

Hot code loading on the BEAM gives the reload. A native kernel that can be
restarted under live children gives the safety. Supervision is the second
line, not the first.

## Decision: BEAM, not an embedded scripting layer

The goal is "the agent edits everything", including pane coordination, the
API, persistence, and remote. An embedded Lua layer in the current Rust
(mlua, as wezterm/neovim/yazi do) was considered and rejected: it would give
the same reload latency for keybinds, layout, chrome, and detection rules,
but everything below that stays Rust with multi-second rebuilds, which caps
the agent at "edits what you see".

The BEAM is the only option that gives in-process code swap with retained
heaps, ~100ms per-module compile, per-process isolation, and a real language
for the ~100k lines of application logic that are rewritten either way.

## The split

```
┌──────────────────────── BEAM (Elixir, hot-reloadable) ─────────────────────┐
│  app state · actions · keybinds · layout · frame composition & overlays    │
│  input parsing · detection · OSC trackers · plugins · config · persistence │
│  API · remote attach · reload loop                                         │
└───────────────┬───────────────────────────────────────────┬────────────────┘
                │ packed cells, pty writes, pane commands    │ dirty rows, OSC
                ▼                                            │ events, exits
┌──────────────────────── native kernel (Rust NIFs via Rustler) ─────────────┐
│  libghostty-vt · PTY (portable-pty / ConPTY) · host tty raw mode & input   │
│  key/mouse/focus encoding (ghostty) · cell blitter · OSC/DCS splitter      │
└────────────────────────────────────────────────────────────────────────────┘
```

Rules:

- **No raw PTY stream bytes enter the BEAM.** The kernel reads the PTY on its
  own thread and feeds ghostty. The BEAM receives packed dirty rows on
  request and structured events (`{:osc, id, code, payload}`, exits, bells).
- **The kernel contains no presentation decisions.** It hands the BEAM cells
  and writes back cells. Selection, dimming, hover links, scrollbars, kitty
  placement, and chrome are all composed in Elixir. This is what keeps the
  kernel stable enough that it is almost never the thing being edited.
- **The kernel must be restartable under live children.** herdr's SCM_RIGHTS
  handoff is ported into the second slice, so a kernel change or crash is a
  sub-second restart with PTYs and child processes preserved, not a session
  loss.

### What maps from herdr

Most of this is a rewrite in Elixir, not a port. herdr's `src/app` (38k),
`src/server` (30k), `src/pane` (13k), `src/protocol` (9k), and `src/api`
(9.5k) are the bulk of the brain. The honest reuse is the kernel.

| herdr | herdr-live |
|---|---|
| `crates/ghostty-vt` C-ABI wrapper | `Native.Vt` NIF resource; same calls, plus `dirty_rows` |
| ghostty `KeyEncoder`, `MouseEncoder`, `encode_focus` | `Native.Vt.encode_key/mouse/focus` |
| `src/pty/` | `Native.Pty`; reader and writer threads move inside the NIF |
| `src/protocol/render_ansi.rs` `BlitEncoder` | `Native.Blit`, diff + ANSI only, input is packed cells |
| server-side packed cells for remote clients | the one and only frame path, local and remote |
| `src/raw_input.rs` termios / ioctl | `Native.Tty` |
| `src/raw_input.rs` escape parsing, query windows | Elixir `Input.Parse` (3.9k lines of Rust; not small) |
| feed-path side trackers (agent OSC, default color, kitty kbd, XTGETTCAP, DECSCUSR) | Elixir, fed by kernel OSC/DCS splitter events |
| `AppState` (pure data) | several small structs, see "State layout" |
| `PaneState` / `PaneRuntime` | `Pane.State` / `Native.Keeper` resource owner |
| `compute_view()` → `render()` | `View.compute/2` → `Render.compose/2` → `Native.Blit.frame/3` |
| `src/detect/` + TOML manifests | `Detect` module; regexes vetted for PCRE, `match_limit` set |
| `src/server/handoff.rs` SCM_RIGHTS | ported in slice 2 for kernel restart |

## Supervision tree

```
HerdrLive.Supervisor (one_for_one)
├── Native.Keeper            # Holds every NIF resource and the pane-id table. No logic. Never reloaded.
├── Tty.Owner                # Raw mode on, restores on terminate/2 and on resource destructor. Never reloaded.
├── Reload.Supervisor        # watcher, compiler, rollback (see below)
├── App.Store                # GenServer holding the app structs. Thin callbacks; logic in pure modules.
├── Pane.Supervisor          # DynamicSupervisor, one Pane.Server per pane
│   └── Pane.Server          # per-pane: damage → render request, OSC events, detection polling
├── Render.Loop              # event-driven; compose + blit on demand with a minimum interval
├── Input.Reader             # tty bytes → events; focused-pane fast path; else App.Store
├── Api.Listener             # unix socket / JSON API
└── Persist.Writer           # debounced snapshots to disk
```

Invariants:

- `Native.Keeper` and `Tty.Owner` are the only processes holding OS
  resources. Everything else refers to panes by id. The kernel monitors every
  subscriber (`enif_monitor_process`); a restarted `Pane.Server` resubscribes
  and receives a forced full-damage.
- Thin GenServers call pure functions in `App.Actions`, `View`, `Render`,
  `Layout`, `Input.Parse`, `Detect`. Reloading a pure module needs no state
  migration.
- Supervisor intensity breaches are a *secondary* rollback trigger. The
  primary trigger is the failure counter inside `safe_apply` (below), because
  `safe_apply` by construction prevents crashes.

## State layout

`App.State` is split so hot-path edits do not fan out:

- `App.Session` — workspaces, tabs, pane tree. Changes rarely.
- `App.Focus` — focused pane, mode, modal stack. Tiny; read on every keystroke.
- `App.Ui` — sidebar, theme, chrome preferences. Edited often; nothing else
  depends on its struct at compile time.
- `Pane.State` — per pane, held by `Pane.Server`, mirrored to ETS per row.

Rules enforced at dev time by `safe_apply`:

- No local funs (`:erlang.fun_info(f, :type) == :local`) anywhere in
  persisted state. Keybind tables are `{M, F, A}` tuples. A reload of a module
  whose closure lives in some process heap would otherwise hard-kill that
  process on the *second* load, which reads as random.
- Every callback begins `state = Map.merge(%Struct{}, state)` so additive
  fields pick up defaults.
- Shape changes get `code_change/3`; a wrong one is caught at the
  `safe_apply` boundary and rolled back with state intact.

## NIF interface (kernel)

Rustler, one crate. Blocking work happens on kernel-owned threads. Every
kernel thread loop runs under `catch_unwind` and reports a panic as
`{:exit, id, {:panic, reason}}`; the crate builds with `panic = "unwind"`.
Dirty schedulers are used only for bounded calls (`read_text` of large
ranges); frame work is never queued behind them.

### Native.Vt

One `ghostty_terminal`, owned by `Native.Keeper`. Internally the kernel keeps
a per-pane `RenderState` snapshot that the reader thread refreshes under a
short lock between chunks; BEAM-facing reads iterate the snapshot outside the
lock, so a `cat` of a large file cannot stall a scheduler on a contended
mutex. Scalar accessors use `try_lock` and return `{:stale, value}` when
contended.

```elixir
@spec new(cols, rows, max_scrollback) :: {:ok, vt}
@spec resize(vt, cols, rows, cell_px) :: :ok
@spec dirty_rows(vt) :: {gen :: integer, [{row :: n, cells :: binary}]}   # packed cell format, refc binaries
@spec full_rows(vt) :: {gen, [{n, binary}]}
@spec read_text(vt, :viewport | :screen | {:rows, range}) :: binary        # dirty-cpu
@spec scrollbar(vt) :: %{total: n, viewport: n, offset: n}
@spec scroll_to(vt, offset) :: :ok           # viewport is owned by ghostty, never by BEAM state
@spec mode(vt, mode_id) :: boolean | {:stale, boolean}
@spec kitty_keyboard_flags(vt) :: integer
@spec link_at(vt, x, y) :: nil | %{uri: binary, kind: atom}
@spec encode_key(vt, key_event) :: binary    # ghostty KeyEncoder, uses live modes
@spec encode_mouse(vt, mouse_event) :: binary | nil
@spec encode_focus(vt, boolean) :: binary
@spec graphics_placements(vt, viewport) :: [placement]   # kitty images intersecting the viewport
```

Packed cell format: fixed-width records (grapheme ref or inline codepoints,
fg, bg, attrs, width, link id) so `Render.compose` can slice and overlay with
binary pattern matching rather than per-cell term construction. This is the
same shape herdr already sends to remote clients.

### Native.Pty

```elixir
@spec spawn(vt, cmd, args, env, cwd, cols, rows) :: {:ok, pty, os_pid}
@spec write(pty, binary) :: :ok | {:error, :backpressure}   # enqueue to the writer thread, never blocks
@spec resize(pty, cols, rows, cell_px) :: :ok
@spec kill(pty, signal) :: :ok
@spec subscribe(pty, pid) :: :ok
@spec set_hidden(pty, boolean) :: :ok
```

Threads per PTY:

- **Reader**: pulls bytes, runs the OSC/DCS splitter, calls
  `ghostty_terminal_write`, refreshes the `RenderState` snapshot, emits
  `{:damage, id, gen}` to subscribers at most once per 4ms *while output is
  flowing* and immediately on quiescence. Hidden panes parse but do not emit.
- **Writer**: one ordered queue shared by BEAM input and ghostty's own PTY
  responses (DA, DSR, XTGETTCAP, color queries), which arrive via
  `WritePtyCallback` on the reader thread. Bounded; `write/2` reports
  backpressure instead of blocking a scheduler.

Events to subscribers: `{:damage, id, gen}`, `{:exit, id, status}`,
`{:osc, id, code, payload}`, `{:dcs, id, payload}`, `{:bell, id}`,
`{:title, id, binary}`, `{:pwd, id, binary}`. OSC 52 payloads are capped and
truncated with a flag.

### Native.Tty

```elixir
@spec open() :: {:ok, tty}            # /dev/tty, raw mode, kitty kbd query
@spec restore(tty) :: :ok             # idempotent; also runs from the resource destructor
@spec size(tty) :: {cols, rows, px_w, px_h}
@spec subscribe(tty, pid) :: :ok      # {:tty_input, binary}
@spec write(tty, iodata) :: :ok       # enqueue to host-tty writer thread; bounded; drops frames when behind
@spec suspend(tty) :: :ok             # restore, SIGSTOP own pgrp; re-raw on SIGCONT, emits {:tty_resumed}
```

SIGWINCH is handled on the BEAM side (`:os.set_signal(:sigwinch, :handle)`)
followed by `size/1`; no signal handlers are installed from the NIF. The VM
runs `-noshell -noinput`; `Logger` goes to a file, never stdout.

### Native.Blit

```elixir
@spec frame(tty, rows :: [{n, binary}], %{cursor: {x, y} | nil, shape: atom, repaint: boolean}) :: :ok
```

Pure cell blitter: takes packed rows for the whole host screen, diffs against
the retained last frame (one copy, budgeted), writes ANSI wrapped in
synchronized output on a dedicated writer thread. It knows nothing about
panes. The remote client runs the identical blitter against rows received
over the wire.

## Rendering pipeline

```
{:damage, id, gen} ──► Pane.Server ──► Render.Loop (render now if idle; else mark pending)
                                              │
                                              ▼
                                   View.compute(session, focus, ui, tty_size)
                                              │  pure; returns layout: rects per pane + chrome specs
                                              ▼
                                   Render.compose(layout, &Native.Vt.dirty_rows/1)
                                              │  pure given the row fetcher; slices pane rows into
                                              │  screen rows, applies overlays (selection, dim,
                                              │  hover links, scrollbar, kitty placements), draws chrome
                                              ▼
                                   Native.Blit.frame(tty, rows, cursor)
```

- `Render.Loop` is event-driven with a minimum inter-frame interval (e.g.
  6ms), not a fixed tick. An idle multiplexer renders a keystroke's echo as
  soon as the damage arrives.
- `Render.compose` is the module most likely to be edited live, and it is
  now in the brain. Fifteen full-screen panes are ~150k cells; at the packed
  format that is a few MB of refc binary slicing per full repaint and far
  less for dirty-row updates. The slice measures this.
- Kitty graphics: `graphics_placements/2` gives image ids and rects; compose
  clips them to pane rects and emits placement commands alongside the cells.

## Input pipeline

```
{:tty_input, bin} ──► Input.Reader
                        │ Input.Parse.events(bin, parser_state)   # parser_state lives in the GenServer
                        ▼
              fast path: no modal, no matching bind, focused pane known
              (from :persistent_term) ──► Native.Vt.encode_key ──► Native.Pty.write
                        │ otherwise
                        ▼
              App.Store ──► App.Actions.apply(state, event) ──► pty writes / state change
```

The fast path keeps the big `App.Store` heap (and its GC) out of the
keystroke-to-glass path for ordinary typing. `App.Store` publishes
`{focused_pty, keybind_table, modal?}` to `:persistent_term` whenever they
change.

## Hot reload

### Compilation

Single-file `Code.compile_file` is wrong: structs, macros, `use`, behaviours,
and protocol impls are compile-time dependencies, and a module compiled
against the old `%Struct{}` literal keeps the old defaults. The watcher drives
Mix's incremental compiler, which recompiles dependents from its manifest.
`consolidate_protocols: false` in dev so reloaded impls are seen.

Consequence: the cost of an edit is its dependency fan-out, which is why
`App.State` is split above. "Add a field to `App.Ui` under load" is a slice
metric.

### Loading

Per batch:

1. Watcher debounces 50ms, runs the compiler in a Task.
2. Compile error: status-line notice, nothing loads.
3. Record `{batch_id, modules, previous_beams, state_at_load}` in a ring of
   depth N. `state_at_load` is one immutable reference; cheap.
4. `:code.soft_purge` each module; if it fails (a process still runs old
   code), report which process and fall back to hard purge only for modules
   known to have no long-lived frames.
5. `:code.load_binary`. Reset the per-module failure counters.

### `safe_apply`

Every thin GenServer wraps its single call into editable code:

```elixir
def handle_call({:event, ev}, _from, state) do
  case Reload.Guard.run(App.Actions, :apply, [state, ev], budget_ms: 50) do
    {:ok, new_state} ->
      {:reply, :ok, new_state}
    {:failed, reason} ->
      # Guard has already rolled back the responsible batch and reloaded
      # the previous beams. Re-apply the same event on the old code so
      # resizes, key releases, and mode changes are never dropped.
      {:ok, new_state} = Reload.Guard.run(App.Actions, :apply, [state, ev], budget_ms: 50)
      {:reply, :ok, new_state}
  end
end
```

`Reload.Guard.run` catches `raise`, `throw`, and `exit`, enforces a deadline
(the call runs in a linked task that is killed on timeout, so a hang in
`View.compute` is a failure, not a wedge), and attributes the failure to the
most recent batch that touched a module on the stack trace. One attributed
failure triggers synchronous rollback. A blanket catch is justified only here,
at the boundary between fixed and live-edited code.

### Rollback

1. Reload `previous_beams` for the batch. Process heaps are untouched, so
   state is kept exactly. Re-apply the failed event.
2. If the old code fails on the same event (the new code silently corrupted
   state), restore `state_at_load`, then **reconcile**: compare state's pane
   ids against `Native.Keeper`'s table; adopt panes spawned in the window
   into a scratch tab, drop references to panes that were killed. State and
   the live resource set are consistent again; the user loses the
   non-terminal actions since the reload.
3. The rollback window is keyed on *exercise*, not wall clock: a batch stays
   attributable until each reloaded module has handled some number of calls
   without failure, with a wall-clock floor. The user exercising the changed
   feature thirty seconds later still rolls back the right batch.
4. A manual `herdr-live rollback [n]` command walks the ring.
5. Terminals are unaffected in every case; `Native.Keeper` owns them.

### ETS mirror

`Pane.Server` and `App.Store` mirror state to ETS tables owned by
`Native.Keeper` (`heir` set). `:ets.insert` copies the term, so the mirror is
debounced (tens of ms) and per pane / per sub-struct, never whole-state on the
keystroke path. If a GenServer dies, the supervisor restarts it from ETS,
not disk, and sends a full-damage to the renderer.

### What hot reload does not cover

NIF modules are not reloaded. Kernel changes and kernel crashes (a Zig
safety-check abort in libghostty takes the VM) are handled by the handoff
path: the new VM starts, receives PTY and tty fds over SCM_RIGHTS from the
dying one plus serialized per-pane state (herdr's `HandoffRuntimeState`), and
replays scrollback into fresh ghostty terminals. Target under one second with
children alive. Until this lands, a kernel restart means session restore from
disk and lost children, which is why it is slice 2 and not "later".

## Protocols and remote

- Fork, so bincode codecs and endpoint generations are gone. ETF between BEAM
  nodes, JSON on the public socket.
- Remote attach: a client node runs `Tty.Owner`, `Input.Reader`,
  `Render.Loop`, and `Native.Blit` locally and receives composed packed rows
  from the server for its own size. Because local rendering already works on
  packed rows, this is the same path with a socket in it. Per-client sizes
  and cell px are handled in `View.compute` per client. TLS distribution or
  a plain socket over SSH; never expose epmd.

## Windows

BEAM runs on Windows. ConPTY is a `Native.Pty` backend; console input is a
`Native.Tty` backend. Defer until the Unix slices are proven.

## Slices and go/no-go

### Slice 1: the hard cases, deliberately

Build: `Native.Vt` (with `dirty_rows`, encoders), `Native.Pty` (reader +
writer threads, splitter), `Native.Tty`, `Native.Blit`; `App.Session` with a
tile layout; `Input.Parse` for CSI u, legacy keys, SGR mouse; `View.compute`
and `Render.compose` with a status bar; `Reload` with Guard and rollback.

| metric | target |
|---|---|
| keystroke → glass, local echo, idle | ≤ herdr + 1ms p95 |
| frame cost, 1 vs 15 full panes, fixed geometry | within 2× herdr's ratio |
| `cat` 100MB in 15 panes | no scheduler stall > 10ms; typing in another pane stays ≤ 20ms |
| edit `Render.compose`, save → visible | < 500ms p95 |
| add a field to `App.Ui` under load → visible | < 1s p95; record the fan-out module count |
| add a field to `App.Session` | record fan-out; this is the known-expensive case |
| infinite loop introduced in `View.compute` | rollback within budget + 100ms, no dropped resize |
| second reload of a module whose closure was placed in state | rejected at dev time with a message, not a killed process |
| rollback after a pane was spawned inside the window | state reconciled, pane adopted, nothing orphaned |
| reload while `cat` runs in 15 panes | compile competes for cores; measure save → visible |

### Slice 2: kernel restart under live children

Port SCM_RIGHTS handoff. Metric: kill the VM with `kill -9` while 15 shells
run; new VM attached with all children alive and scrollback restored in
under one second.

### Slice 3: breadth

Copy mode and selection across pane boundaries, kitty graphics in composed
frames, detection and OSC trackers in Elixir, plugins, persistence, API,
remote.

## Risks that remain

- **Rewrite size.** Roughly 100k lines of application logic are rewritten,
  not ported. The kernel is the only real reuse. The slices exist to find out
  early whether the architecture holds before that bill is paid.
- **Composition cost in Elixir.** Packed binaries and dirty rows should make
  it fine; if 15-pane full repaints miss the metric, the fallback is a
  compose-helper NIF that takes the layout and overlay list but still holds no
  policy.
- **Kernel abort takes the VM** until slice 2 lands, and remains a
  one-second hiccup after it.
- **PCRE on manifest regexes.** Backtracking on 2000-char lines with `.*`
  can go superlinear. Vet manifests and set `match_limit`; if it bites, match
  in the kernel with the `regex` crate.
- **Reaping and signals next to erts.** `waitpid` on known pids and
  `os:set_signal` should coexist with the VM, but it is tested in slice 1,
  not assumed.
