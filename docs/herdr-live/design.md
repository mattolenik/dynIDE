# herdr-live: design sketch

Status: exploratory, revision 3 (critical review folded in; multi-frontend
contract added). This is a fork direction, not a change to herdr.

## Goal

An agent edits the IDE's source while you are using it, and the running IDE
reflects each change in under a second without losing terminals, scrollback,
or layout. A bad edit must never take the IDE down.

The terminal is the first frontend, not the only one. A GUI frontend is
planned, so the server never assumes it is talking to a terminal.

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

Three layers. The server owns sessions and state; clients own a display and
an input device; the kernel owns bytes and OS resources on both sides.

```
┌────────────────────── clients (one per attached display) ───────────────────────┐
│  terminal client (Elixir)              │  GUI client (future; LiveView-in-webview │
│  Client.Term.Input: tty bytes → events │  or native)                              │
│  Client.Term.Render: scene → cells     │  scene → widgets, rows → glyphs          │
│  herdr_term NIF: tty raw mode, blitter │                                          │
└───────────────┬────────────────────────┴───────────────────┬──────────────────────┘
                │ neutral events (key, mouse, paste, focus, resize)
                │                                            │ scene + packed rows
                ▼                                            │ per client
┌──────────────────────── server (Elixir, hot-reloadable) ───────────────────────┐
│  app state · actions · keybinds · layout · scene construction · overlays       │
│  detection · OSC trackers · plugins · config · persistence · API · reload loop │
└───────────────┬────────────────────────────────────────────┬───────────────────┘
                │ pty writes, pane commands                   │ dirty rows, OSC
                ▼                                             │ events, exits
┌──────────────────────── herdr_kernel (Rust NIFs via Rustler) ──────────────────┐
│  libghostty-vt · PTY · key/mouse/focus encoding (ghostty) · OSC/DCS splitter   │
└────────────────────────────────────────────────────────────────────────────────┘
```

Rules:

- **No raw PTY stream bytes enter the BEAM.** The kernel reads the PTY on its
  own thread and feeds ghostty. The server receives packed dirty rows on
  request and structured events (`{:osc, id, code, payload}`, exits, bells).
- **The kernel contains no presentation decisions.** It hands the server
  cells and, on the terminal client side, writes back cells. Selection,
  dimming, hover links, scrollbars, kitty placement, and chrome are all
  decided in Elixir.
- **The server contains no display decisions.** It produces a *scene* (see
  "Scene contract"): pane rects, per-pane row references, a declarative
  chrome tree, focus, cursor. It never emits a cell of chrome or an escape
  sequence. Rasterizing chrome to cells is the terminal client's job;
  drawing widgets is a GUI client's job.
- **Frontends are clients, even locally.** The terminal client runs in the
  same VM as the server for a local session, but talks to it only through
  the client protocol. Remote attach is the same client over a socket; a GUI
  is another client. Nothing is reachable only from inside the terminal
  client.
- **The kernel must be restartable under live children.** herdr's SCM_RIGHTS
  handoff is part of slice 1, so a kernel change or crash is a sub-second
  restart with PTYs and child processes preserved, not a session loss.

### What maps from herdr

Most of this is a rewrite in Elixir, not a port. herdr's `src/app` (38k),
`src/server` (30k), `src/pane` (13k), `src/protocol` (9k), and `src/api`
(9.5k) are the bulk of the server. The honest reuse is the kernel. herdr's
own runtime/client guardrail ("shared runtime facts in the server, TUI
presentation state in the client") carries over unchanged and is now
structural rather than advisory.

| herdr | herdr-live |
|---|---|
| `crates/ghostty-vt` C-ABI wrapper | `Native.Vt` NIF resource (`herdr_kernel`); same calls, plus `dirty_rows` |
| ghostty `KeyEncoder`, `MouseEncoder`, `encode_focus` | `Native.Vt.encode_key/mouse/focus` |
| `src/pty/` | `Native.Pty` (`herdr_kernel`); reader and writer threads move inside the NIF |
| `src/protocol/render_ansi.rs` `BlitEncoder` | `Native.Blit` (`herdr_term`), diff + ANSI only, input is packed cells |
| server-side packed cells for remote clients | the one and only pane-content path, every client |
| `src/raw_input.rs` termios / ioctl | `Native.Tty` (`herdr_term`) |
| `src/raw_input.rs` escape parsing, query windows | `Client.Term.Input` (3.9k lines of Rust; not small) |
| feed-path side trackers (agent OSC, default color, kitty kbd, XTGETTCAP, DECSCUSR) | server, fed by kernel OSC/DCS splitter events |
| `AppState` (pure data) | several small structs, see "State layout" |
| `PaneState` / `PaneRuntime` | `Pane.State` / `Native.Keeper` resource owner |
| `compute_view()` | `View.compute/2` → scene |
| `render()` | `Client.Term.Render` (scene + rows → cells) → `Native.Blit.frame/3` |
| TUI sidebar/tabs/modals drawing code | chrome *tree* in the scene; drawn per client |
| `src/detect/` + TOML manifests | `Detect` module; regexes vetted for PCRE, `match_limit` set |
| `src/server/handoff.rs` SCM_RIGHTS | ported in slice 1 for kernel restart |

## Repo layout

Mix umbrella under `live/`:

- `apps/herdr_scene` — the scene and event contracts, pure data and
  validators, no processes. Both server and clients depend on it; nothing
  else is shared.
- `apps/herdr_server` — everything in the server layer; depends on
  `herdr_kernel` (Rustler crate at `live/native/herdr_kernel`).
- `apps/herdr_term` — terminal client; depends on `herdr_term` NIF crate at
  `live/native/herdr_term`.
- A future `apps/herdr_gui` depends on `herdr_scene` only.

The two NIF crates share no code except through `crates/ghostty-vt` (which
only `herdr_kernel` needs) and the packed cell format spec, which lives in
`herdr_scene` with test vectors both crates must pass.

## Scene contract

The scene is the frontend-neutral output of `View.compute/2`, defined in
`herdr_scene`. It is the one contract a GUI must satisfy, so it is kept
small and explicit:

```elixir
%Scene{
  size: %{cols: n, rows: n},              # client's cell grid; GUI clients report one too
  panes: [%Scene.Pane{
    id: pane_id,
    rect: %{x: n, y: n, w: n, h: n},
    rows: {:ref, pane_id, gen} | {:inline, [{n, binary}]},   # packed rows; ref for local, inline over the wire
    cursor: %{x: n, y: n, shape: atom, visible: boolean} | nil,
    overlays: [%Scene.Overlay{}]          # selection ranges, link hovers, dim, scrollbar; semantic, not cells
    graphics: [placement]
  }],
  chrome: Scene.Node.t(),                 # declarative tree: :sidebar, :tabs, :status, :modal, :text, :button ...
  focus: %{pane: pane_id | nil, chrome: path | nil},
  cursor: %{x: n, y: n, shape: atom} | nil   # the host cursor the client should show
}
```

Rules:

- Chrome nodes carry *roles and content*, never glyphs or colours. A `:tabs`
  node lists tabs with titles, states, and which is active; the terminal
  client decides the box-drawing characters and the GUI decides the widget.
  Theme tokens (`:accent`, `:muted`) are names resolved per client.
- Layout is in cells on both sides, because pane content is cells
  regardless. A GUI client reports a cell size derived from its font and
  window; sub-cell chrome layout is the GUI's own business.
- Overlays are semantic (`{:selection, from, to}`, `{:dim, :inactive}`,
  `{:link_hover, id}`), so a GUI can render them natively.
- Pane rows are `{:ref, ...}` for an in-VM client, which fetches them from
  `Native.Vt.dirty_rows/1` itself, and `{:inline, ...}` for any client
  behind a socket. The server chooses based on the client's transport.

The input vocabulary is the other half of the contract:

```elixir
{:key, %{key: atom | binary, mods: [atom], event: :press | :release | :repeat, text: binary | nil}}
{:mouse, %{kind: :press | :release | :move | :drag | :scroll, button: atom, x: n, y: n, mods: [atom], px: {x, y} | nil}}
{:paste, binary}
{:focus, boolean}
{:resize, %{cols: n, rows: n, cell_px: {w, h} | nil}}
{:chrome, path, action}      # a click on a chrome node, resolved by the client to a path in the tree
```

`App.Actions.apply/2` consumes only these. The terminal client's
`Client.Term.Input` produces them from escape sequences; a GUI produces them
from its toolkit's events.

## Client protocol

Between a client and the server, regardless of transport:

- Client → server: `{:attach, %{kind: :term | :gui, size, cell_px, caps}}`,
  input events as above, `{:detach}`.
- Server → client: `{:scene, %Scene{}}` on every change relevant to that
  client, `{:rows, pane_id, gen, [{n, binary}]}` for inline transports,
  `{:notice, ...}` for client-local outcomes (a rejected action, a reload
  notice), `{:handoff, ...}` during kernel restart.

One `Client.Session` process per attached client on the server side owns
that client's size, kind, and per-client presentation state (viewport
offsets it has requested, hover position). `View.compute/2` runs per client
because sizes differ. Locally this is a message between two process groups
in one VM; the metric table below has to show that hop is free.

Transport: in-VM message passing for the local terminal client, a plain
socket over SSH or TLS distribution for remote, never epmd exposed.

## Supervision trees

Server:

```
HerdrServer.Supervisor (one_for_one)
├── Native.Keeper            # Holds every kernel resource and the pane-id table. No logic. Never reloaded.
├── Reload.Supervisor        # watcher, compiler, rollback (see below)
├── App.Store                # GenServer holding the app structs. Thin callbacks; logic in pure modules.
├── Pane.Supervisor          # DynamicSupervisor, one Pane.Server per pane
│   └── Pane.Server          # per-pane: damage → scene invalidation, OSC events, detection polling
├── Client.Supervisor        # DynamicSupervisor, one Client.Session per attached client
│   └── Client.Session       # per-client size/kind; runs View.compute; pushes scenes
├── Api.Listener             # unix socket / JSON API and client-protocol socket
└── Persist.Writer           # debounced snapshots to disk
```

Terminal client (one per terminal; the local one lives in the same VM):

```
HerdrTerm.Supervisor (one_for_one)
├── Tty.Owner                # Raw mode on, restores on terminate/2 and on resource destructor. Never reloaded.
├── Client.Term.Input        # tty bytes → neutral events; focused-pane fast path; parser state lives here
└── Client.Term.Render       # scene + rows → cells; event-driven; Native.Blit.frame
```

Invariants:

- `Native.Keeper` (server) and `Tty.Owner` (client) are the only processes
  holding OS resources. Everything else refers to panes by id. The kernel
  monitors every subscriber (`enif_monitor_process`); a restarted
  `Pane.Server` resubscribes and receives a forced full-damage.
- Thin GenServers call pure functions in `App.Actions`, `View`, `Layout`,
  `Client.Term.Render`, `Client.Term.Input.Parse`, `Detect`. Reloading a
  pure module needs no state migration.
- Supervisor intensity breaches are a *secondary* rollback trigger. The
  primary trigger is the failure counter inside `safe_apply` (below), because
  `safe_apply` by construction prevents crashes.
- A client crash never touches session state. A server-side `Client.Session`
  crash is a detach/re-attach from the client's point of view.

## State layout

Server state is split so hot-path edits do not fan out:

- `App.Session` — workspaces, tabs, pane tree. Changes rarely.
- `App.Focus` — focused pane, modal stack. Tiny; read on every keystroke.
- `App.Ui` — sidebar, theme, chrome preferences. Edited often; nothing else
  depends on its struct at compile time.
- `Pane.State` — per pane, held by `Pane.Server`, mirrored to ETS per row.
- `Client.State` — per attached client, held by `Client.Session`: kind, size,
  cell px, requested viewports, hover, and input mode (prefix/resize), as in
  tmux's per-client key tables. Presentation and per-client input state live
  here, never in `App.*`.

Rules enforced at dev time by `safe_apply`:

- No local funs (`:erlang.fun_info(f, :type) == :local`) anywhere in
  persisted state. Keybind tables are `{M, F, A}` tuples. A reload of a module
  whose closure lives in some process heap would otherwise hard-kill that
  process on the *second* load, which reads as random.
- Every callback begins `state = Map.merge(%Struct{}, state)` so additive
  fields pick up defaults.
- Shape changes get `code_change/3`; a wrong one is caught at the
  `safe_apply` boundary and rolled back with state intact.

## NIF interfaces

Two Rustler crates. Blocking work happens on kernel-owned threads. Every
kernel thread loop runs under `catch_unwind` and reports a panic as
`{:exit, id, {:panic, reason}}`; both crates build with `panic = "unwind"`.
Dirty schedulers are used only for bounded calls (`read_text` of large
ranges); frame work is never queued behind them.

### herdr_kernel: Native.Vt

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
fg, bg, attrs, width, link id) so clients can slice and overlay with binary
pattern matching rather than per-cell term construction. This is the same
shape herdr already sends to remote clients. The spec and test vectors live
in `herdr_scene`.

### herdr_kernel: Native.Pty

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

### herdr_term: Native.Tty

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

### herdr_term: Native.Blit

```elixir
@spec frame(tty, rows :: [{n, binary}], %{cursor: {x, y} | nil, shape: atom, repaint: boolean}) :: :ok
```

Pure cell blitter: takes packed rows for the whole host screen, diffs against
the retained last frame (one copy, budgeted), writes ANSI wrapped in
synchronized output on a dedicated writer thread. It knows nothing about
panes or scenes. A remote terminal client runs the identical blitter against
rows received over the wire.

## Rendering pipeline

```
{:damage, id, gen} ──► Pane.Server ──► Client.Session (per client; render now if idle; else mark pending)
                                              │
                                              ▼
                                   View.compute(session, focus, ui, client_state)
                                              │  pure; returns %Scene{} for this client
                                              ▼
                                   push {:scene, scene} to the client
                                              │
                        ┌─────────────────────┴──────────────────────┐
                        ▼                                            ▼
             terminal client                                  GUI client (future)
             Client.Term.Render.compose(scene, &rows/1)       draw chrome tree as widgets;
               rasterize chrome tree to cells; slice pane      blit pane rows as glyph runs;
               rows into screen rows; apply overlays;          draw overlays natively
               place graphics
                        ▼
             Native.Blit.frame(tty, rows, cursor)
```

- `Client.Session` is event-driven with a minimum inter-frame interval (e.g.
  6ms), not a fixed tick. An idle multiplexer renders a keystroke's echo as
  soon as the damage arrives. Scenes are only pushed when they differ from
  the last one sent to that client; row damage alone is pushed as
  `{:rows, ...}` or, for an in-VM client, as a bare invalidation so it
  fetches `dirty_rows` itself.
- `View.compute` and `Client.Term.Render` are the modules most likely to be
  edited live, and both are in the brain. Fifteen full-screen panes are
  ~150k cells; at the packed format that is a few MB of refc binary slicing
  per full repaint and far less for dirty-row updates. The slice measures
  this.
- Kitty graphics: `graphics_placements/2` gives image ids and rects; the
  scene carries them per pane; the terminal client clips and emits placement
  commands alongside the cells, a GUI client blits the image.

## Input pipeline

```
{:tty_input, bin} ──► Client.Term.Input
                        │ Input.Parse.events(bin, parser_state)   # parser_state lives in the GenServer
                        ▼
              fast path: no modal, no matching bind, focused pane known
              (from :persistent_term, in-VM clients only)
                        ──► Native.Vt.encode_key ──► Native.Pty.write
                        │ otherwise
                        ▼
              neutral event ──► Client.Session ──► App.Store ──► App.Actions.apply(state, event)
```

The fast path keeps the big `App.Store` heap (and its GC) out of the
keystroke-to-glass path for ordinary typing. `App.Store` publishes
`{focused_pty, keybind_table, modal?}` to `:persistent_term` whenever they
change. Remote and GUI clients send every event through the protocol; the
server applies the same fast-path check in `Client.Session` before touching
`App.Store`.

## Hot reload

### Compilation

Single-file `Code.compile_file` is wrong: structs, macros, `use`, behaviours,
and protocol impls are compile-time dependencies, and a module compiled
against the old `%Struct{}` literal keeps the old defaults. The watcher drives
Mix's incremental compiler, which recompiles dependents from its manifest.
`consolidate_protocols: false` in dev so reloaded impls are seen.

Consequence: the cost of an edit is its dependency fan-out, which is why
state is split above and why `herdr_scene` is a separate app that changes
rarely: an edit to the scene structs recompiles both server and client.
"Add a field to `App.Ui` under load" is a slice metric.

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

Reload applies to every Elixir app in the umbrella, so the terminal client's
`Render` and `Input` modules are as live as the server's. A GUI client in
Elixir (LiveView) gets the same treatment; a GUI in another language
reloads by its own means or not at all, which is the main argument for
LiveView-in-webview.

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
at the boundary between fixed and live-edited code. `Client.Term.Render` and
`Client.Session` use the same guard around `compose` and `View.compute`.

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

`Pane.Server`, `App.Store`, and `Client.Session` mirror state to ETS tables
owned by `Native.Keeper` (`heir` set). `:ets.insert` copies the term, so the
mirror is debounced (tens of ms) and per pane / per sub-struct / per client,
never whole-state on the keystroke path. If a GenServer dies, the supervisor
restarts it from ETS, not disk, and pushes a full scene to affected clients.

### What hot reload does not cover

NIF modules are not reloaded. Kernel changes and kernel crashes (a Zig
safety-check abort in libghostty takes the VM) are handled by the handoff
path: the new VM starts, receives PTY and tty fds over SCM_RIGHTS from the
dying one plus serialized per-pane state (herdr's `HandoffRuntimeState`), and
replays scrollback into fresh ghostty terminals. Target under one second with
children alive. It is part of slice 1 because without it a kernel restart
means session restore from disk and lost children. Clients see
`{:handoff, ...}` and re-attach to the new VM; a remote client's socket is
handed over the same way.

## Protocols and remote

- Fork, so bincode codecs and endpoint generations are gone. ETF between BEAM
  nodes, JSON on the public API socket; the client protocol is ETF or a
  length-prefixed binary framing of the same terms.
- Remote attach is the terminal client (`apps/herdr_term`) running in its own
  VM with the client protocol over a socket. Scenes arrive with
  `{:inline, rows}`. Nothing else differs from the local case.
- A GUI client is the same protocol with `kind: :gui`. The leading candidate
  is a LiveView app rendered in a webview (Tauri/wry) or a browser: the
  client stays in Elixir, hot reload and the Guard apply to it, pane rows
  render to a canvas, and the server does not change. A native toolkit
  client is possible but loses live editing of its own code.

## Windows

Deferred and unscheduled. BEAM runs on Windows; ConPTY would be a
`Native.Pty` backend and console input a `Native.Tty` backend. Kernel restart
needs a non-SCM_RIGHTS mechanism there. Keep platform code behind the
`Native.*` contracts so nothing makes it harder later.

## Slices and go/no-go

### Slice 1: the hard cases, deliberately

Build: `Native.Vt` (with `dirty_rows`, encoders), `Native.Pty` (reader +
writer threads, splitter), `Native.Tty`, `Native.Blit`; `herdr_scene` with
the scene and event contracts; `App.Session` with a tile layout;
`Client.Session` and the client protocol with the local terminal client
attached through it; `Client.Term.Input` for CSI u, legacy keys, SGR mouse;
`View.compute` producing a scene with a status-bar chrome node and
`Client.Term.Render` rasterizing it; `Reload` with Guard and rollback; and
kernel restart under live children (SCM_RIGHTS handoff), because that is the
mechanism behind "never lose terminals" and the gate should prove it.

| metric | target |
|---|---|
| keystroke → glass, local echo, idle | ≤ herdr + 1ms p95 (includes the client-protocol hop) |
| frame cost, 1 vs 15 full panes, fixed geometry | 15-pane full repaint ≤ herdr's at the same geometry; record the 1 vs 15 ratio (M6 gate change: was "within 2× herdr's ratio") |
| `cat` 100MB in 15 panes | typing in another pane stays ≤ 20ms p95; scheduler stall no worse than the host's OS-only floor (a BEAM probe next to 15 pty floods with no herdr code), and ≤ 10ms where that floor allows (M6 gate change: was "no scheduler stall > 10ms") |
| edit `Client.Term.Render`, save → visible | < 500ms p95 |
| edit `View.compute` (chrome tree change), save → visible | < 500ms p95 |
| add a field to `App.Ui` under load → visible | < 1s p95; record the fan-out module count |
| add a field to `App.Session` | record fan-out; this is the known-expensive case |
| add a field to a `Scene` struct | record fan-out across server and client apps |
| infinite loop introduced in `View.compute` | rollback within budget + 100ms, no dropped resize |
| second reload of a module whose closure was placed in state | rejected at dev time with a message, not a killed process |
| rollback after a pane was spawned inside the window | state reconciled, pane adopted, nothing orphaned |
| reload while `cat` runs in 15 panes | compile competes for cores; measure save → visible |
| `kill -9` the VM with 15 shells running | new VM attached, all children alive, scrollback restored, < 1s p95 |
| second terminal client attached at a different size | both render correctly; typing in one visible in the other |

### Slice 2: breadth

Copy mode and selection across pane boundaries, kitty graphics in composed
frames, detection and OSC trackers in Elixir, plugins, persistence, API,
remote, GUI client.

## Risks that remain

- **Rewrite size.** Roughly 100k lines of application logic are rewritten,
  not ported. The kernel is the only real reuse. The slices exist to find out
  early whether the architecture holds before that bill is paid.
- **Composition cost in Elixir.** Packed binaries and dirty rows should make
  it fine; if 15-pane full repaints miss the metric, the fallback is a
  compose-helper NIF in `herdr_term` that takes rows and an overlay list but
  still holds no policy. (M6 gate change: measured. The cost that scales with
  panes is Elixir building one term per pane row segment, not byte copying, so
  a row-assembly NIF saved nothing at 15 panes; the next lever, if per-segment
  work grows, is a NIF that places whole pane rectangles. See
  `results/m6-gate.md`.)
- **PTY floods starve the schedulers (M6 gate change).** Parallel PTY floods
  cost the OS kernel super-linear sys CPU (macOS) or plain CPU contention
  (Linux) and preempt BEAM scheduler threads; no process on the host escapes
  it. The kernel demotes a reader that floods (macOS utility QoS, Linux nice
  10) and promotes it on the first read after an idle window; on Linux the
  nice is sticky without `CAP_SYS_NICE`.
- **Scene abstraction leaking terminal assumptions.** The chrome tree will be
  designed with only a terminal renderer to test it against. Mitigation: a
  throwaway HTML renderer for the scene (a few hundred lines, dev-only) in
  slice 2 to prove a second renderer can consume it before the GUI milestone.
- **Client-protocol hop on the local path.** One extra process boundary per
  keystroke and per frame. Expected to be tens of microseconds; the metric
  table checks it rather than assuming.
- **Kernel abort takes the VM** until handoff lands within slice 1, and
  remains a one-second hiccup after it.
- **PCRE on manifest regexes.** Backtracking on 2000-char lines with `.*`
  can go superlinear. Vet manifests and set `match_limit`; if it bites, match
  in the kernel with the `regex` crate.
- **Reaping and signals next to erts.** `waitpid` on known pids and
  `os:set_signal` should coexist with the VM, but it is tested in slice 1,
  not assumed.
