# herdr-live

herdr forked onto the BEAM: Elixir server and clients over a Rust NIF kernel,
so an agent can edit the running multiplexer and see it in under a second
without losing terminals, scrollback, or layout. A bad edit never takes it down.
Rules come from `docs/herdr-live/design.md` (it wins over this file),
`milestones.md`, and `status.md` (ledger, rulings) in the same directory.

## Operating model

- Milestone work happens on branch `live/m<N>` in worktree
  `../herdr-live-worktrees/m<N>`, branched from `herdr-live`.
- The coordinator session owns the `herdr-live` integration branch and
  `docs/herdr-live/status.md`. Milestone owners do not edit status.md.
- Parallel owners rebase on `herdr-live` when a sibling lands, before their
  own merge.
- Never push. Owners commit on their branch without proposing messages first.
- Results: `docs/herdr-live/results/m<N>.md`. ADRs:
  `docs/herdr-live/adr/NNNN-short-title.md`, copied from `0000-template.md`.
- Human decisions only at the M6 gate ADR, M7 dogfooding week, M15 GUI ADR.

## The split

Server owns sessions and state; clients own a display and an input device;
the kernel owns bytes and OS resources on both sides.

- No raw PTY stream bytes enter the BEAM. The kernel reads the PTY, feeds
  ghostty, and sends packed dirty rows on request plus structured events.
- The kernel makes no presentation decisions. Selection, dimming, links,
  scrollbars, kitty placement, and chrome are decided in Elixir.
- The server makes no display decisions. It emits a scene, never a cell of
  chrome or an escape sequence.
- Frontends are clients, even locally: the in-VM terminal client uses only
  the client protocol, and nothing is reachable only from inside it.
- The kernel must be restartable under live children (SCM_RIGHTS handoff).

Shared session facts (pane/agent metadata, process and terminal state,
events) belong in the server and its API; presentation state (colours,
selection, hover, requested viewports) belongs in the client or
`Client.State`, never `App.*`. Server API, event, and runtime-fact names stay
neutral (no sidebar/row/widget); chrome roles like `:sidebar` and `:tabs` are
scene vocabulary and fine.

## Scene contract

`HerdrScene` defines the scene and input vocabulary, the one contract a GUI
must satisfy. Keep it small; an edit to it recompiles server and clients.

- Chrome nodes carry roles and content, never glyphs or colours. Theme tokens
  (`:accent`, `:muted`) are names resolved per client.
- Layout is in cells on both sides. Overlays are semantic
  (`{:selection, from, to}`, `{:dim, :inactive}`), not cells.
- Pane rows are `{:ref, ...}` for in-VM clients, `{:inline, ...}` over a
  socket. `App.Actions.apply/2` consumes only the neutral input events.

## Repo layout

- `live/` is a Mix umbrella. `live/apps/herdr_scene`: pure contracts and
  validators, no processes, no umbrella deps. `live/apps/herdr_server`:
  server layer. `live/apps/herdr_term`: terminal client. `live/apps/herdr_reload`:
  the reloader. `live/apps/herdr_cli`: the `herdr-live` CLI (depends only on
  herdr_scene; talks JSON to the API socket). `live/apps/herdr_scene_html`:
  dev-only HTML scene renderer (`mix herdr.scene.html`), depends only on
  herdr_scene, nothing depends on it. `live/apps/herdr_integration`:
  test-only, may depend on all of them.
- Plugins (M14): herdr's external-process plugin model, unchanged, under
  `HerdrServer.Plugins.*`; plugins run as OS processes (argv, never a shell)
  driven through the manifest, the pane env (`HERDR_PANE_ID`,
  `HERDR_LIVE_BIN`/`HERDR_BIN_PATH`, `HERDR_LIVE_API`/`HERDR_SOCKET_PATH`)
  and the API. No plugin code is ever loaded into the VM (human ruling).
  The upstream examples have no licence, so they are not in the tree:
  `live/scripts/plugin_examples.sh` fetches pinned commit `18709cd` into
  `${XDG_CACHE_HOME:-~/.cache}/herdr-live/plugin-examples/18709cd` for the install
  smoke and the `:examples` tests (`HERDR_LIVE_OFFLINE=1` forbids fetching;
  no cache and no network skips them).
- Kitty graphics (M10): ghostty computes placements in the kernel; the
  server publishes them through `Pane.Facts` into `Scene.Pane.graphics`; the
  pure `Render.Graphics` pass runs after Compose (never inside `Overlays`),
  clips to the pane, crops around top-layer chrome, overlays and popup panes,
  and `Native.Blit` writes the kitty ops inside synchronized output. A new
  overlay type needs an occluder clause in `Render.Graphics`. Images are not
  persisted; a graceful kernel handoff carries on-screen and virtual
  placements and their pixels (16 MiB per pane) as a VT replay in the final
  pane blob (`Vt.graphics_replay/2`), a `kill -9` does not (M18). `t=t` files
  go in `/tmp/herdr-live-kitty-<euid>/herdr-live-gfx-<pid>/`.
- Chrome: 19 node roles with required props in `HerdrScene.Chrome`; golden
  fixtures in `live/apps/herdr_scene/priv/fixtures/scenes` (every role must
  have one and render in both the terminal client and the HTML renderer).
  User config is herdr's TOML format at
  `${XDG_CONFIG_HOME:-~/.config}/herdr-live/config.toml` (`$HERDR_LIVE_CONFIG`
  overrides), reloaded with `prefix R`.
- Agent detection (M11): `HerdrServer.Detect.*` (Manifests, Regions, Engine,
  Identify, Tracker, Poller, Watcher). Bundled manifests (herdr's, verbatim) are
  in `live/apps/herdr_server/priv/detect/manifests`; local overrides in
  `<config dir>/agent-detection/<label>.toml` win; the watcher reloads on save.
  CLI: `herdr-live agent list|get|read|explain|wait|prompt|send-keys`,
  `server agent-manifests|reload-agent-manifests`,
  `pane report-agent|release-agent`. See `docs/herdr-live/results/m11.md`.
- Modules live under the app root module: design `Native.Vt` is
  `HerdrServer.Native.Vt`, `Client.Term.Input` is `HerdrTerm.Client.Term.Input`.
- NIF crates: `live/native/herdr_kernel` (NIF module `HerdrServer.Native`,
  links `crates/ghostty-vt`, which builds vendored libghostty-vt with Zig
  0.16.0) and `live/native/herdr_term` (NIF module `HerdrTerm.Native`).
  Rustler `~> 0.38.0`, crate `=0.38.0`. One NIF module per crate; the
  design's `Native.*` modules are Elixir facades over it.
- Other crates: `live/native/herdr_fdpass` (SCM_RIGHTS frame codec shared by
  kernel and broker) and `live/native/herdr_broker` (the broker binary: VM
  supervisor, fd and blob holder, warm standby, handoff state machine, host
  tty guard). `live/live.just` lists every crate in `live_crates`.
- Each crate is its own Cargo workspace (empty `[workspace]`), so no root
  `[patch.crates-io]` is inherited: set `[patch.crates-io] portable-pty` with
  `path = "../../../vendor/portable-pty"` when a crate needs portable-pty.
- `live/bin/herdr-live`: dev launcher. It runs the broker, which spawns the
  VM (`mix run --no-halt` under `-noshell -noinput`) plus one warm standby;
  stdio goes to `$HERDR_LIVE_LOG` (default
  `${XDG_STATE_HOME:-$HOME/.local/state}/herdr-live/herdr-live.log`).
  SIGTERM stops it cleanly with no handoff. Attached (a tty, not
  `HERDR_LIVE_HEADLESS=1`), the broker runs under `scripts/tty_guard.sh`, which
  restores the host tty after a broker `kill -9` and logs `herdr-event
  broker_killed signal=N` (`tty_harness.py broker-kill`). Subcommands: `kernel-restart`
  (graceful handoff), `status`, `rollback [n]`. Smoke tests:
  `live/scripts/launcher_smoke.sh`, `attached_smoke.sh`,
  `live/bench/handoff/smoke.exs`. A VM learns its role over the link when
  `HERDR_BROKER_SOCK` is set; without it (tests, iex) it starts standalone.
- Remote attach (M16): the server listens on `client.sock` (0600, in the
  0700 dir of the API socket; `$HERDR_LIVE_CLIENT_SOCK` overrides) with a
  token in `client.token` beside it (0600). `herdr-live attach [<host>]
  [<session>]` starts the terminal client in its own VM (stdio to
  `$HERDR_LIVE_CLIENT_LOG`, default `client.log` beside the server log); with
  a host it runs `ssh -T -o BatchMode=yes <host> herdr-live attach-relay`,
  and the relay on the server host reads the token, so it never travels
  (`$HERDR_LIVE_SSH`, `$HERDR_LIVE_REMOTE_BIN`). Contract: `HerdrScene.Wire`.
  Results: `docs/herdr-live/results/m16.md`.
- Plugins (M14): `HerdrServer.Plugins.*` runs herdr's external-process plugins
  (manifest, registry, runtime, panes, link handlers) under herdr's paths re-rooted
  at `herdr-live/`; no plugin code ever loads into the VM.
- The `plugins` tty harness mode (two herdr example plugins from
  the cached upstream checkout, unmodified) is in `just live-check`.
- Persistence (M8, ADR 0002): under the broker the session saves to
  `<state dir>/session.<name>.etf` (schema v2, atomic, 0600) and scrollback
  (last 1000 rows as VT) to `session.<name>.scrollback/<pane id>.etf`. State dir:
  `HERDR_LIVE_STATE_DIR`, else `$HERDR_LIVE_RUNTIME_DIR/state`, else
  `${XDG_STATE_HOME:-~/.local/state}/herdr-live`. `HERDR_LIVE_SESSION` names it
  (default `default`); `HERDR_LIVE_PERSIST=0` disables. Tests and standalone
  `mix run` never persist. Restore order: broker carry > ETS mirror > disk.
- The Rust herdr product (`src/`) was pruned in M7. It lives on as the git tag
  `herdr-reference`; `live/bench/gate/herdr_ref.sh` builds it from the tag when a
  benchmark needs the reference binary.

Adding an app: from `live/`, `mix new apps/<name>`; depend only on
`{:herdr_scene, in_umbrella: true}` (and optionally `{:herdr_reload, in_umbrella: true}`); set
`consolidate_protocols: Mix.env() == :prod`.
`live/apps/herdr_scene/test/dependency_rule_test.exs` discovers `apps/*`,
asserts every app except `herdr_scene` has `[:herdr_scene]` or
`[:herdr_reload, :herdr_scene]` as its umbrella deps (`herdr_reload` exactly
`[:herdr_scene]`, `herdr_scene` none), and enforces `consolidate_protocols`.

Adding a NIF: a `#[rustler::nif]` fn (auto-registered by `rustler::init!`)
plus `def name(...), do: :erlang.nif_error(:nif_not_loaded)` in the crate's
Elixir NIF module, and a facade function in the `Native.*` module it belongs to.

## Principles

- **State is separate from runtime.** `Native.Keeper` (server) and `Tty.Owner`
  (client) are the only processes holding OS resources; everything else
  refers to panes by id. Thin GenServers call pure modules (`App.Actions`,
  `View`, `Layout`, `Client.Term.Render`, `Client.Term.Input.Parse`,
  `Detect`), which are testable without PTYs, NIFs, or processes.
- **Render is pure.** `View.compute/2` returns a scene and
  `Client.Term.Render` turns scene + rows into cells; neither mutates state
  or performs I/O. `Native.Blit` is the I/O end: it diffs packed rows and
  writes ANSI, with no knowledge of panes or scenes.
- **No god objects.** Split modules that do too many things; GenServer
  callbacks stay thin.
- **Platform code is isolated.** OS APIs live in the NIF crates (the reference
  `src/platform/` is in the `herdr-reference` tag); Elixir core has no OS branches.
- **Detection is evidence-based.** Match explicit AND/OR gates over the
  bottom-buffer detection source, never whole-pane incidental text or the
  user-scrollable viewport. Live loop: `Detect.*` and the manifests above,
  `herdr-live agent read`/`explain` (docs/herdr-live/editing-live.md "Agent
  detection manifests"). The reference loop is in the `herdr-reference` tag.
- **UI patterns are reused.** Mouse-first. New dialogs and flows reuse the
  existing chrome roles and interaction patterns instead of one-off screens.
- **Multiplicative performance paths.** Work reachable from damage handling,
  `View.compute`, `Client.Term.Render`, blitting, PTY reading, detection, and
  scene/row fanout multiplies: per byte or event x panes x attached clients.
  Do per-pane damage, not full repaints; push scenes only when they differ;
  keep kernel locks short (`try_lock` for scalars); never queue frame work
  behind dirty schedulers; hidden panes parse but do not emit damage.

## State layout

- `App.Session` (workspaces, tabs, pane tree), `App.Focus` (focused pane,
  modal stack), `App.Ui` (sidebar, theme, chrome prefs), `Pane.State`
  (per pane, in `Pane.Server`), `Client.State` (per client, in
  `Client.Session`; includes that client's input mode such as prefix, like
  tmux per-client key tables). Do not merge them; edits fan out by compile deps.
- No local funs in persisted state. Keybinds are `{M, F, A}` tuples (MFA).
- Every callback begins `state = Map.merge(%Struct{}, state)`.
- Shape changes get `code_change/3`.

## Hot reload

- Recompile through Mix's incremental compiler, never `Code.compile_file`.
- `consolidate_protocols: Mix.env() == :prod` (false in dev and test).
- Calls from thin GenServers into editable code go through `safe_apply` /
  `Reload.Guard.run`. That boundary is the only place a blanket
  `rescue`/`catch` of raise, throw, and exit is allowed.
- NIF modules are not hot reloaded; kernel changes go through handoff
  (`herdr-live kernel-restart`). Clients get
  `{:handoff, %{phase: :begin | :aborted | :released | :adopted, ...}}`;
  hold input on `:begin`, replay on `:aborted`, re-attach on `:released`.
  The reload pipeline runs only in the primary VM.

## Editing herdr-live from inside herdr-live

Full guide: `docs/herdr-live/editing-live.md`. Human checks: `docs/herdr-live/results/m7-manual-checklist.md`.

- Edit under `live/apps/*/lib` and save: the Watcher compiles and loads in
  ~200-500 ms. Edits to `herdr_scene` fan out to server and client, so batch
  them. NIF crates and `native/` changes need `herdr-live kernel-restart`.
- A new field in a persisted struct needs a `code_change/3` that merges
  defaults. A new session fact (`App.Session`, pane metadata) also needs a
  `Persist.Schema` field and a migration (`@migrations`, bump `version/0`);
  `App.Ui` fields persist generically (plain data only). No `fn` in state (rejected at the guard). Guarded call sites
  stay thin; blanket `rescue` stays in `HerdrReload.Guard`.
- A second terminal onto the running instance: `"$HERDR_LIVE_BIN" attach`
  (no host, local socket). It resumes after a drop within 60 s and stays
  attached through `kernel-restart`; `prefix q` detaches only that client.
- Read the status line (`r<N> <k>m`, `r! compile`, `rolled back`, `synced ..., no
  rollback`, `tests ...`, `handoff ...`); every text is in the guide.
- A rolled-back source reloads only when its content changes: edit or revert
  it, a bare re-save does nothing. `herdr-live rollback [n]` rolls back by hand.
- `herdr-live test-on-save on|off|status` (or `HERDR_LIVE_TEST_ON_SAVE=1`) gates
  saves on the mapped `*_test.exs`; ~1 s per save, off by default.
- Every reload, rollback, handoff and crash logs a `herdr-event` line;
  `just live-log-summary` (`live/scripts/log_summary.py`) summarises the log.
  session_losses = `session_lost` lines (broker fallback restore, Store closing
  or orphaning live panes) + unclean broker restarts; store_restarts are not
  losses, and neither is an operator kill (`broker_killed signal=9`, counted as
  operator_kills with the restart and `session_lost` lines around it).
- Pane shells get `HERDR_PANE_ID`, `HERDR_LIVE_BIN` and `HERDR_LIVE_API` (the API
  socket): `"$HERDR_LIVE_BIN" pane split|run|read|wait-output|list ...` drives the
  running instance; reference in `docs/herdr-live/api.md`. M17 verbs: `worktree
  list|create|open|remove`, `pane zoom|focus-direction|swap|resize`, `pane split
  --cwd/--env`, `tab move`, `workspace move`, `pane|workspace report-metadata`,
  `pane report-agent-session`, `notification show`, `title set|clear`, `popup
  close`; `herdr-live --default-config` prints the commented defaults and
  `completion bash|zsh|fish` a completion script.
- Metrics: `just live-bench-reload|handoff|glass|os-floor`;
  `live/bench/gate_round.sh <tag>` runs the whole slice-1 table. Self-hosted
  tty check: `python3 live/scripts/tty_harness.py selfhost`.
- Inside herdr-live, run `just live-test` and focused tests; run the full
  `just live-check` from another worktree or with the dogfood instance
  stopped (another terminal is not enough: harness and smokes share
  `_build/dev`, selfhost writes into the watched tree). One instance per log
  file (two brokers on one log give false `broker_died` losses). In a herdr-live pane (`HERDR_LIVE_API` set) the tty harness skips
  its launcher modes (`herdr`, `herdr-stress`, `selfhost`) with a SKIP line.
- After any change to the snapshot path or a libghostty-vt bump, re-run
  `cd live && elixir bench/handoff/kill9.exs runs=30` (ADR 0001), and keep or
  drop vendored patch 0008 deliberately.

## Kernel (Rust NIFs)

- Blocking work runs on kernel-owned threads; every thread loop runs under
  `catch_unwind` and reports panics as `{:exit, id, {:panic, reason}}`.
  Both crates set `panic = "unwind"` in dev and release profiles.
- Dirty schedulers only for bounded calls. `write/2` reports backpressure
  instead of blocking a scheduler. No signal handlers installed from a NIF.
- Never write to stdout (VM runs `-noshell -noinput`); `Logger` goes to file.

## Code conventions and testing

- Rust: no `unwrap()` in production code; `tracing` for logging; `#[allow]`
  only with a comment explaining why. Platform code is compile-gated with
  `#[cfg(...)]` on items; `cfg!(...)` only for policy constants.
- No new dependency without a reason. Do not break root `cargo build`.
- `just live-test`: mix and cargo tests. `just live-check` (format, credo
  --strict, dialyzer, cargo fmt/clippy, tests, launcher smoke): run before
  committing. `just live-run` launches. CI: `.github/workflows/live.yml`.
- `just check` is an alias of `live-check`. `just maintenance-test` runs the
  vendoring script tests.

## Vendored libghostty-vt

`vendor/libghostty-vt.vendor.json` records the upstream commit. Each local
patch in `vendor/patches/libghostty-vt/` is indexed in
`vendor/libghostty-vt.patches.md` (why, issue, upstream PR, base commit,
files, verification, removal condition). On update, drop patches upstream
contains and reapply the rest; `just maintenance-test` checks the index.

## Commit style

Lowercase conventional commits, descriptive subjects, no emojis, no AI
co-author lines. Commit explicit paths when other agents share the checkout.
