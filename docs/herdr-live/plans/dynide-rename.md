# dynIDE Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the new BEAM product (herdr-live) to dynIDE: `live/` becomes `dynide/`, every
herdr-live identifier becomes `dynide`, and herdr's reused Rust code and herdr's plugin/pane
contract keep their names.

**Architecture:** A mechanical rename in four green commits (folder, code identifiers,
product surface, docs) plus one audit-and-migrate task. Files move with `git mv`; text
changes come from `git grep -lz … | xargs -0 perl -pi -e …` over an explicit scope that
never includes the keep-list paths. Each task ends with an audit grep that comes back empty
and a passing `just dynide-check` (`just live-check` in Task 1's first step).

**Tech Stack:** Elixir umbrella (Mix), Rust crates (Cargo, rustler 0.38), just, bash,
python3, perl for substitutions.

**Spec:** the user's request (2026-10-25) plus four answered decisions:
1. Elixir: rename app names, module prefixes **and** app/lib dirs (`apps/herdr_server` ->
   `apps/dynide_server`, `lib/herdr_server/` -> `lib/dynide_server/`). Don't restructure
   anything else. The Elixir code stays inside `dynide/` as it is now under `live/`.
2. The `live/native/*` crates are new code: rename them `dynide_*`.
3. Docs: `git mv docs/herdr-live docs/dynide`. Rewrite the living docs. In historical
   records, fix only paths.
4. Clean break: no legacy env vars or fallback paths in code. Local state is moved by
   hand in Task 5.

## Global Constraints

- **Name style:** in prose and user-facing titles (docs, README, AGENTS.md, moduledoc
  sentences, CLI help description line, Homebrew `desc`, Nix `description`) write
  `dynIDE`. Commands, paths, file names, crates, OTP apps, atoms, log tags and test names
  use `dynide`. Elixir module aliases use `Dynide…`, because the language requires a capital.
  Env vars use `DYNIDE_…`, following shell convention.
- **Where:** branch `dynide-rename` from `herdr-live`, worktree
  `../herdr-live-worktrees/dynide-rename`. Never work in `/Users/matt/herdr-project/herdr-live`:
  the dogfood instance runs from its `live/` (broker
  `live/native/herdr_broker/target/release/herdr_broker`, a watcher on `live/apps/*/lib`).
  Never push.
- **Moves:** `git mv` only, so history follows. Every substitution is a whole-token
  regex. Never run a bare `s/herdr/dynide/`.
- **Commits:** lowercase conventional, no emojis, no AI co-author lines, explicit paths
  (`git add -A dynide docs …` is fine inside the dedicated worktree).
- **Status ledger:** add one line to `docs/dynide/status.md` in Task 5. No other prose
  edits there.

### Rename map (old -> new)

| Old | New |
|---|---|
| dir `live/` | `dynide/` |
| `live/live.just`, just vars `live_dir`, `live_crates`, recipes `live-*` (all 17), `import 'live/live.just'` | `dynide/dynide.just`, `dynide_dir`, `dynide_crates`, `dynide-*`, `import 'dynide/dynide.just'` |
| `.github/workflows/live.yml`, its job `live-check`, cache keys `live-…`, concurrency group `live-…` | `dynide.yml`, `dynide-check`, `dynide-…` |
| `bin/live-demo`, `LIVE_DEMO_LOG` | `bin/dynide-demo`, `DYNIDE_DEMO_LOG` |
| OTP apps and dirs `herdr_scene`, `herdr_server`, `herdr_term`, `herdr_reload`, `herdr_cli`, `herdr_integration`, `herdr_scene_html` (also `lib/<app>/`, `lib/<app>.ex`, `test/<app>…`) | `dynide_*` |
| modules `HerdrScene`, `HerdrServer`, `HerdrTerm`, `HerdrReload`, `HerdrCli`, `HerdrIntegration`, `HerdrSceneHtml` (+ `…Test`) | `DynideScene`, `DynideServer`, … |
| `Mix.Tasks.Herdr.*`; tasks `herdr.api.docs`, `herdr.bench`, `herdr.reload_bench`, `herdr.scene.html`; files `lib/mix/tasks/herdr.*.ex` | `Mix.Tasks.Dynide.*`; `dynide.*` |
| crates/dirs `native/herdr_kernel`, `native/herdr_term`, `native/herdr_fdpass`, `native/herdr_broker`; `rustler::init!("HerdrServer.Native")`, `("HerdrTerm.Native")` | `dynide_*`; `"DynideServer.Native"`, `"DynideTerm.Native"` |
| broker binary `herdr_broker`, log prefix `herdr-broker:` | `dynide_broker`, `dynide-broker:` |
| our atoms and names `:herdr_*` (ETS, registered, persistent_term, telemetry: `herdr_pane_facts`, `herdr_link`, `herdr_link_closed`, `herdr_pane_kernel`, `herdr_pane_rows`, `herdr_mirror`, `herdr_local_client`, `herdr_stress`, `herdr_stall_…`, …) | `:dynide_*` |
| Mix release `herdr_live`, release script `bin/herdr_live` | `dynide_vm`, `bin/dynide_vm` (not `dynide`: that would collide with the launcher copied into the same `bin/`) |
| launcher and CLI `herdr-live`, `bin/herdr-live`, completion fn `_herdr_live` | `dynide`, `bin/dynide`, `_dynide` |
| `HERDR_LIVE_<X>` | `DYNIDE_<X>` (e.g. `HERDR_LIVE_BIN` -> `DYNIDE_BIN`, `HERDR_LIVE_API` -> `DYNIDE_API`, `HERDR_LIVE_BENCH_BIN` -> `DYNIDE_BENCH_BIN`) |
| our other vars `HERDR_BROKER_SOCK`, `HERDR_GUARD_EVENT_LOG`, `HERDR_BENCH_*`, `HERDR_RELOAD_BENCH_*`, `HERDR_REAL_KERNEL_TMP`, `HERDR_FRESH_APT`, `HERDR_FRESH_IMAGE`, `HERDR_UPDATE_FIXTURES` | `DYNIDE_` + same suffix |
| path segment `herdr-live` in config/state/cache/runtime dirs; `herdr-live.log`; `~/.herdr-live/worktrees`; `/tmp/herdr-live-kitty-<euid>/herdr-live-gfx-<pid>/`; `herdr-live-*` temp names | `dynide`; `dynide.log`; `~/.dynide/worktrees`; `/tmp/dynide-kitty-<euid>/dynide-gfx-<pid>/`; `dynide-*` |
| log tag `herdr-event`; lines `herdr-live started|stopped` | `dynide-event`; `dynide started|stopped` |
| our temp/fixture prefixes `herdr-…`/`herdr_…` (tests, scripts, bench, `herdr-m*-check` podman images, CI `herdr-zig-0.16.0`) | `dynide-…`/`dynide_…` |
| `tty_harness.py` class `Herdr`, modes `herdr`, `herdr-stress`; `glass.py` mode `herdr-live` | `Dynide`, `dynide`, `dynide-stress`; `dynide` |
| `rel/packaging/homebrew/herdr-live.rb.in` (`class HerdrLive`), nix `pname`/`mainProgram`/`mkHerdrLive`, tarball `herdr-live-<V>-<os>-<arch>.tar.gz`, `updates.herdr-live.invalid` | `dynide.rb.in` (`class Dynide`), `dynide`/`mkDynide`, `dynide-<V>-…`, `updates.dynide.invalid` |
| persisted envelopes `format: :herdr_live_session`, `:herdr_live_scrollback` | `:dynide_session`, `:dynide_scrollback`; reads also accept the old atom (the only legacy path) |
| `docs/herdr-live/` | `docs/dynide/` |

### Keep list (stays `herdr`)

- **Untouched paths:** `crates/`, `vendor/`, root `scripts/`, root `Cargo.toml`/`Cargo.lock`,
  `rust-toolchain.toml`, `FORK.md`, `LICENSE`, `dynide/apps/dynide_server/priv/detect/manifests/`.
- **herdr's pane/plugin env contract:** `HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`,
  `HERDR_ENV`, `HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`, `HERDR_CLIENT_SOCKET_PATH`,
  `HERDR_PANE_RUNTIME_ID`, `HERDR_PLUGIN_*`, `HERDR_ACTIVE_*`.
- **Driving the reference binary:** `HERDR_BIN`, `HERDR_SESSION`, `HERDR_DISABLE_SOUND`,
  `bench/gate/herdr_ref.sh`, `herdrref*`, `glass.py` mode `herdr`, git tag `herdr-reference`
  (and its cache subdir name, which now sits under `~/.cache/dynide/`).
- **herdr's plugin format:** `herdr-plugin.toml`, `min_herdr_version`,
  `invalid_plugin_min_herdr_version`, `plugin_requires_newer_herdr`, the `{"id","result"}`
  envelope, URLs `ogulcancelik/herdr`, `herdr-plugin-examples`. Also the `herdr` tracing
  target emitted by `crates/ghostty-vt`, so a filter string like `herdr=info` stays.
- **Repo/process names:** homepage `github.com/mattolenik/herdr`, git branches `herdr-live`
  and `live/m<N>`, and the worktree dir `../herdr-live-worktrees/`. These aren't code, and
  AGENTS.md keeps describing them as they are.
- **Prose** where "herdr" means the upstream product ("herdr's TOML format").
- **Historical records** (`docs/dynide/plans/`, `results/`, `adr/0001*`, `adr/0002*`, the
  `status.md` ledger): prose stays as written. Only paths change.

## Review Focus

1. **A keep-list name renamed anyway.** A plugin would get `DYNIDE_PANE_ID` and never see
   `HERDR_PANE_ID`, so plugins and agent hooks break silently. Pinned by Task 3 Step 4.
2. **A session saved before the rename.** After the manual `mv`, `session.default.etf`
   still has `format: :herdr_live_session`. Without a clause that names the atom,
   `binary_to_term(.., [:safe])` fails and the file is quarantined, so the layout is lost.
   Pinned by Task 3 Step 1.
3. **`bin/dynide` colliding with the release script.** The release copies the launcher
   into the same `bin/`. The release is named `dynide_vm`. Pinned by `release_smoke.sh`
   in Task 3 Step 6.
4. **Callers outside the repo** (user hooks, shell rc, `~/.claude` settings) still calling
   `herdr-live` or `$HERDR_LIVE_BIN`. Covered by the grep in Task 5 Step 5.
5. **The running dogfood instance and stale untracked trees.** Fast-forwarding while the
   broker runs from `live/` deletes its watched sources. Untracked `live/_build`, `live/deps`
   and `live/native/*/target` survive the merge. Covered by Task 5 Steps 3-4.

---

### Task 1: Move `live/` to `dynide/`

**Files:**
- Move: `live/` -> `dynide/`, `dynide/live.just` -> `dynide/dynide.just`,
  `dynide/bin/live-demo` -> `dynide/bin/dynide-demo`, `.github/workflows/live.yml` ->
  `.github/workflows/dynide.yml`
- Modify: `justfile`, `dynide/dynide.just`, `.github/workflows/dynide.yml`, and every
  file under `dynide/` whose text contains a `live/` path, `live_dir`, `live_crates`,
  `LIVE_DEMO_LOG` or a `live-*` recipe name

**Interfaces:**
- Produces: tree root `dynide/`, `just dynide-check`, `just dynide-test`, `dynide_dir`,
  `dynide_crates`. Later tasks run these.

- [ ] **Step 1: Create the worktree and take a baseline**

```bash
git -C /Users/matt/herdr-project/herdr-live worktree add ../herdr-live-worktrees/dynide-rename -b dynide-rename herdr-live
cd /Users/matt/herdr-project/herdr-live-worktrees/dynide-rename && just live-check
```
Expected: exit 0. A red baseline is not this plan's problem: stop and report it.

- [ ] **Step 2: Audit (expected to fail)**

```bash
git grep -n -P '(?<![\w.-])live/|live\.just|\blive_(dir|crates)\b|LIVE_DEMO_LOG|(?<![\w-])live-(test|check|log-summary|run|demo|bench|release)' -- . ':!docs' ':!crates' ':!vendor' ':!scripts' ':!FORK.md'
```
Expected: many hits.

- [ ] **Step 3: Move and substitute**

Do the four `git mv`s above. Then run perl over the audit's file list: `live/` (with the
same lookbehind, so `herdr-live/` and `.live/` never match) -> `dynide/`, `live.just` -> `dynide.just`, `live_dir`/`live_crates` ->
`dynide_dir`/`dynide_crates`, `live-<recipe>` -> `dynide-<recipe>` for the 17 recipes in
`dynide.just`, and `LIVE_DEMO_LOG` -> `DYNIDE_DEMO_LOG`. In `dynide.yml`, also rename the
job, the concurrency group and the cache key prefixes `live-` -> `dynide-`. Drop the
`README.md`/`AGENTS.md` hits from this pass; Task 4 rewrites both.

- [ ] **Step 4: Audit passes**

Rerun Step 2's command with `':!README.md' ':!AGENTS.md'` added. Expected: no output.

- [ ] **Step 5: Gate**

Run: `rm -rf dynide/_build && just dynide-check`
Expected: exit 0. Build paths are absolute, so `_build` copied before the move would
compile against `live/`.

- [ ] **Step 6: Commit**

```bash
git add -A dynide justfile .github && git commit -m "refactor: move live/ to dynide/ and rename live-* recipes"
```

---

### Task 2: Rename code identifiers (apps, modules, mix tasks, crates, atoms)

These go in one commit because `herdr_term` is both an app and a crate, and
`rustler::init!` binds crate code to Elixir module names.

**Files:**
- Move: `dynide/apps/herdr_*` -> `dynide/apps/dynide_*`. Inside each app:
  `lib/herdr_*` -> `lib/dynide_*`, `lib/herdr_*.ex` -> `lib/dynide_*.ex`, any
  `test/herdr_*` dir or file -> `test/dynide_*`, and `lib/mix/tasks/herdr.*.ex` ->
  `lib/mix/tasks/dynide.*.ex`. Also `dynide/native/herdr_*` -> `dynide/native/dynide_*`.
- Modify: every file under `dynide/`, plus `.github/workflows/dynide.yml`, that matches
  Step 1's audit. Includes each `mix.exs`, each `Cargo.toml` (package/lib/bin names, the
  `herdr_fdpass` path deps), `rustler::init!` lines, `use Rustler … crate:`, `dynide.just`
  `dynide_crates`, `.credo.exs`, the dialyzer config, `scripts/fixtures/dogfood-sample.log`,
  scene fixtures, and the CI cache paths.
- Regenerate: `dynide/native/*/Cargo.lock` (cargo rewrites the package names).

**Interfaces:**
- Consumes: Task 1's `dynide/` layout and `just dynide-check`.
- Produces: OTP apps `:dynide_*`, modules `Dynide*`, mix tasks `dynide.api.docs`,
  `dynide.bench`, `dynide.reload_bench`, `dynide.scene.html`, broker binary
  `dynide/native/dynide_broker/target/release/dynide_broker` that logs as `dynide-broker:`.

- [ ] **Step 1: Audit (expected to fail)**

```bash
git grep -n -P 'Herdr(Scene|Server|Term|Reload|Cli|Integration)|\bherdr_(scene|server|term|reload|cli|integration|kernel|fdpass|broker)|Mix\.Tasks\.Herdr|\bherdr\.(api|bench|reload_bench|scene)|herdr-broker|:herdr_(?!live_)[a-z]' -- dynide .github
```
Expected: about 6,000 hits.

- [ ] **Step 2: Move the dirs and files** (list above). Run `git status --short | grep -c '^R'`:
  the count should be the number of tracked files under `apps/` and `native/`.

- [ ] **Step 3: Substitute**

`Herdr(Scene|Server|Term|Reload|Cli|Integration)` -> `Dynide$1` (this also covers
`HerdrSceneHtml` and `…Test`). `\bherdr_(scene|server|term|reload|cli|integration|kernel|fdpass|broker)`
-> `dynide_$1`. `Mix.Tasks.Herdr.` -> `Mix.Tasks.Dynide.`. `\bherdr\.(api\.docs|bench|reload_bench|scene\.html)\b`
-> `dynide.$1`. `herdr-broker` -> `dynide-broker`. Then rename every other `:herdr_<name>`
atom and `herdr_<name>` registered/ETS/persistent_term name defined in `dynide/apps/*/lib`
to `dynide_<name>`. List the leftovers with
`git grep -h -o -E '\bherdr_[a-z_]+' -- dynide | sort -u`, then rename each one that isn't
on the keep list (`herdr_ref`). Leave `herdr_live` for Task 3.

- [ ] **Step 4: Audit passes.** Rerun Step 1's command. Expected: no output.

- [ ] **Step 5: Gate**

Run: `rm -rf dynide/_build dynide/apps/*/priv/native && just dynide-check`
Expected: exit 0, including `dependency_rule_test.exs` (it discovers `apps/*`, so it now
checks the `dynide_*` names) and the architecture atom test.

- [ ] **Step 6: Commit**

```bash
git add -A dynide .github && git commit -m "refactor: rename herdr_* apps, modules, crates and atoms to dynide"
```

---

### Task 3: Rename the product surface (CLI, release, env vars, paths, logs, packaging)

**Files:**
- Move: `dynide/bin/herdr-live` -> `dynide/bin/dynide`,
  `dynide/rel/packaging/homebrew/herdr-live.rb.in` -> `dynide.rb.in`
- Modify: everything under `dynide/` plus `justfile` and `.github/workflows/dynide.yml`
  that matches Step 2's audit. Key spots: `dynide/mix.exs` (release name, `@update_url`,
  the `File.cp!` of the launcher), `dynide/bin/dynide`, `dynide_cli` (`argv.ex`,
  `completion.ex`, `update.ex` vm_argv regexes, `client.ex`), `dynide_server`
  (`plugins/env.ex` `@vm_only`, `config.ex`, `persist/disk.ex`, `api/socket_path.ex`,
  `api/spec*.ex`), `dynide_term` (`remote/args.ex`, `render.ex`), `scripts/tty_guard.sh`,
  `scripts/log_summary.py`, `scripts/tty_harness.py`, `scripts/release/*`, `rel/packaging/**`,
  `bench/**`
- Test: `dynide/apps/dynide_server/test/persist/disk_test.exs`
- Regenerate: `docs/herdr-live/api.md` via `mix dynide.api.docs` (the path moves in Task 4)

**Interfaces:**
- Consumes: Task 2's names.
- Produces: command `dynide` (`dynide attach`, `dynide kernel-restart`, `dynide update`, …),
  release `dynide_vm`, env vars `DYNIDE_*` (pane shells get `DYNIDE_BIN`, `DYNIDE_API` and,
  unchanged, `HERDR_PANE_ID`/`HERDR_BIN_PATH`/`HERDR_SOCKET_PATH`), config dir
  `${XDG_CONFIG_HOME:-~/.config}/dynide/`, state dir `${XDG_STATE_HOME:-~/.local/state}/dynide/`,
  cache `${XDG_CACHE_HOME:-~/.cache}/dynide/`, log `dynide.log`, log tag `dynide-event`.

- [ ] **Step 1: Write the failing legacy-envelope tests in `disk_test.exs`**

After Step 3 renames the format atom, the file's `envelope/1` helper writes
`:dynide_session`. These two tests pin the old atom explicitly:

```elixir
test "reads a session saved under the pre-rename envelope atom", %{cfg: cfg, path: path} do
  File.mkdir_p!(cfg.dir)
  File.write!(path, envelope(%{format: :herdr_live_session}))
  assert {:ok, _snap, 1} = Disk.read(cfg)
end

test "reads scrollback saved under the pre-rename envelope atom", %{cfg: cfg} do
  File.mkdir_p!(Disk.scrollback_dir(cfg))
  env = %{format: :herdr_live_scrollback, v: 1, cols: 80, bytes: "abc"}
  File.write!(Path.join(Disk.scrollback_dir(cfg), "7.etf"), :erlang.term_to_binary(env))
  assert Disk.read_scrollback(cfg, 7) == "abc"
end
```
Check the scrollback file name against `scrollback_path/2` in `disk.ex` (currently
`<scrollback_dir>/<id>.etf`). Both tests pass today, since the old atom is the current
one. They become the regression guard once Step 3 renames the atom: run them right after
Step 3 and confirm they fail until the legacy clauses are in.

- [ ] **Step 2: Audit (expected to fail)**

```bash
git grep -n -E 'herdr[-_]live|HERDR_LIVE|HerdrLive|herdr-event|\bHERDR_(BROKER_SOCK|GUARD_EVENT_LOG|BENCH_|RELOAD_BENCH_|REAL_KERNEL_TMP|FRESH_|UPDATE_FIXTURES)|class Herdr\b|\bherdr-(stress|zig|m[0-9])' -- dynide justfile .github
```
Expected: about 2,000 hits.

- [ ] **Step 3: Substitute, in this order**

1. `git mv` the two files.
2. `HERDR_LIVE_BENCH_BIN` -> `DYNIDE_BENCH_BIN`, then `HERDR_LIVE_` -> `DYNIDE_`, then
   the "our other vars" row of the rename map.
3. `\bherdr_live\b` -> `dynide_vm` where it is the release name or `bin/herdr_live`.
   `_herdr_live` -> `_dynide`. The persisted envelopes become `:dynide_session` /
   `:dynide_scrollback`; in `disk.ex`, add a second match clause for each old atom in
   `session/1` and `read_scrollback/2`, with a
   `# ponytail: pre-rename files; drop once no session.*.etf predates the rename` comment.
4. `herdr-event` -> `dynide-event`. Then `herdr-live` -> `dynide`, which covers the
   command, paths, `herdr-live.log` -> `dynide.log`, temp names, `.herdr-live/worktrees`,
   kitty dirs and `updates.herdr-live.invalid`. Leave `herdr-live-worktrees` and any
   reference to the git branch `herdr-live` (e.g. `git … herdr-live` in bench and gate
   scripts) unchanged. Review each hit in human-facing sentences
   (help text, moduledoc prose, packaging `desc`/`description`, the justfile header
   comment) and write `dynIDE` there instead.
5. `class HerdrLive` -> `class Dynide`, `mkHerdrLive` -> `mkDynide`, harness `class Herdr` ->
   `class Dynide` and its references, harness modes `herdr`/`herdr-stress` ->
   `dynide`/`dynide-stress` (the mode table and `dynide.just`), `glass.py` mode
   `herdr-live` -> `dynide` (its mode `herdr` stays), `herdr-zig-` -> `dynide-zig-`,
   `herdr-m<N>-` -> `dynide-m<N>-`, and the remaining `herdr-`/`herdr_` temp and fixture
   prefixes.
6. Run `cd dynide && mix dynide.api.docs`.

- [ ] **Step 4: Audit passes and the herdr contract is intact**

Rerun Step 2's audit. The only expected output is the two `herdr_live_*` legacy clauses
(and their test lines) in `disk.ex`/`disk_test.exs`. Then:

```bash
git grep -h -o -E 'HERDR_[A-Z_]+' -- dynide | sort -u
```
Expected: exactly the keep-list names (`HERDR_ACTIVE_*`, `HERDR_BIN`, `HERDR_BIN_PATH`,
`HERDR_CLIENT_SOCKET_PATH`, `HERDR_DISABLE_SOUND`, `HERDR_ENV`, `HERDR_PANE_ID`,
`HERDR_PANE_RUNTIME_ID`, `HERDR_PLUGIN_*`, `HERDR_SESSION`, `HERDR_SOCKET_PATH`,
`HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`). Check that `plugins/env.ex` still emits
`HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`, `HERDR_ENV`, `HERDR_PLUGIN_*`, `HERDR_WORKSPACE_ID`,
`HERDR_TAB_ID` and `HERDR_PANE_ID`, next to `DYNIDE_API` and `DYNIDE_BIN`.

Then list the bare-word hits: `git grep -n -w herdr -- dynide justfile .github`. Each hit
must be a keep-list item or prose about upstream herdr. Rename anything else.

- [ ] **Step 5: Focused tests**

Run: `cd dynide && mix test apps/dynide_server/test/persist/disk_test.exs apps/dynide_server/test/plugins apps/dynide_server/test/api/spec_test.exs`
Expected: PASS, including both legacy-envelope tests.

- [ ] **Step 6: Gate plus release checks**

```bash
rm -rf dynide/_build && just dynide-check
dynide/scripts/release/build.sh --dev-key        # last line: path to dynide-<V>-<os>-<arch>.tar.gz
dynide/scripts/release/release_smoke.sh
dynide/scripts/release/update_check.sh
dynide/scripts/release/package_check.sh
```
Expected: all exit 0. The tarball holds `bin/dynide` (launcher) and `bin/dynide_vm`, and
`dynide --version` prints `dynide <V>`. `fresh_install_check.sh` needs podman: run it if
podman is up, otherwise record it as skipped.

- [ ] **Step 7: Commit**

```bash
git add -A dynide justfile .github docs/herdr-live/api.md
git commit -m "refactor: rename the herdr-live command, release, env vars, paths and log tags to dynide"
```

---

### Task 4: Docs and top-level files

**Files:**
- Move: `docs/herdr-live/` -> `docs/dynide/`
- Modify: `dynide/apps/dynide_server/lib/dynide_server/api/spec/doc.ex` (`@path` ->
  `…/docs/dynide/api.md`), `dynide/apps/dynide_server/test/api/spec_test.exs` (the stale
  message), every `docs/herdr-live/` reference under `dynide/`, `README.md`, `AGENTS.md`
  (`CLAUDE.md` is a symlink to it), the living docs (`design.md`, `milestones.md`,
  `editing-live.md`, `packed-cells.md`, `adr/0000-template.md`, `site/*.md`), and the
  historical records (paths only: `plans/*.md`, `results/**`, `adr/0001*`, `adr/0002*`,
  `status.md`)

**Interfaces:**
- Consumes: every name from Tasks 1-3.
- Produces: `docs/dynide/` (design, milestones, status, results, adr). AGENTS.md
  describes the renamed tree.

- [ ] **Step 1: Audit (expected to fail)**

```bash
git grep -n -E 'docs/herdr-live' -- dynide README.md AGENTS.md
```
Expected: hits in moduledocs, `doc.ex`, `spec_test.exs`, README and AGENTS.

- [ ] **Step 2: Move and fix code references.** Run
`git mv docs/herdr-live docs/dynide`. Then substitute `docs/herdr-live/` ->
`docs/dynide/` under `dynide/`.

- [ ] **Step 3: Fix paths in historical records**

Apply this to `docs/dynide/{plans,results,adr/0001*,adr/0002*,status.md}` only. It
rewrites path tokens and leaves prose alone:

```perl
sub fix { my $p = shift;
  $p =~ s{\bapps/herdr_}{apps/dynide_}g;  $p =~ s{\blib/herdr_}{lib/dynide_}g;
  $p =~ s{\bnative/herdr_}{native/dynide_}g; $p =~ s{\bbin/herdr-live\b}{bin/dynide}g;
  $p =~ s{\blive\.just\b}{dynide.just}g;  $p =~ s{\btasks/herdr\.}{tasks/dynide.}g; $p }
s{(?<![\w.-])live/([^\s`'"()\[\]<>,;]*)}{"dynide/" . fix($1)}ge;
s{docs/herdr-live/}{docs/dynide/}g;
```
Run it as `perl -pi -e 'BEGIN{…sub…} …'` or from a scratch `.pl` file.

- [ ] **Step 4: Rewrite the living docs**

In `README.md`, `AGENTS.md`, `design.md`, `milestones.md`, `editing-live.md`,
`packed-cells.md`, `adr/0000-template.md` and `site/*.md`, apply the full rename map. The
product name in prose is `dynIDE` ("dynIDE is herdr rebuilt on the BEAM…"); commands,
paths, env vars and module names follow the map. AGENTS.md keeps the keep-list facts
(plugin env contract, `herdr-reference`, vendored crates, branch and worktree names).
`docs/dynide/api.md` is generated: don't hand-edit it. The README title becomes
`# dynIDE`.

- [ ] **Step 5: Audit passes**

```bash
git grep -n -P 'herdr[-_]live(?!-worktrees)|HERDR_LIVE|Herdr(Scene|Server|Term|Reload|Cli|Integration|Live)|\bherdr_(scene|server|term|reload|cli|integration|kernel|fdpass|broker)|herdr-(event|broker)|docs/herdr-live|(?<![\w.-])live/' -- . ':!crates' ':!vendor' ':!scripts' ':!FORK.md' ':!docs/dynide/plans' ':!docs/dynide/results' ':!docs/dynide/adr/0001*' ':!docs/dynide/adr/0002*' ':!docs/dynide/status.md'
```
Expected: only Task 3's two legacy-envelope clauses and their tests, plus lines naming
the git branch `herdr-live`. Run
`git grep -n -w herdr -- README.md AGENTS.md docs/dynide/{design,milestones,editing-live}.md docs/dynide/site`
and check each hit means upstream herdr, a branch name or a keep-list contract.

- [ ] **Step 6: Gate**

Run: `cd dynide && mix test apps/dynide_server/test/api/spec_test.exs && cd .. && just dynide-check`
Expected: exit 0 (the api.md staleness test reads `docs/dynide/api.md`).

- [ ] **Step 7: Commit**

```bash
git add -A docs dynide README.md AGENTS.md && git commit -m "docs: rename herdr-live to dynIDE and move docs to docs/dynide"
```

---

### Task 5: Final audit, merge, local migration

Steps 3-6 stop the user's running dogfood instance and move their state. Before Step 3,
ask the user to confirm.

**Files:**
- Modify: `docs/dynide/status.md` (one ledger line)

- [ ] **Step 1: Whole-branch audit**

Rerun Task 4 Step 5's audit and Task 3 Step 4's `HERDR_` list from the worktree root.
Expected: as before. Then:

```bash
git diff --stat herdr-live -- crates vendor scripts FORK.md LICENSE Cargo.toml Cargo.lock rust-toolchain.toml
git diff -M --summary herdr-live -- live/apps/herdr_server/priv/detect/manifests dynide/apps/dynide_server/priv/detect/manifests | grep -v '(100%)'
```
Expected: both print nothing. The manifests are pure 100% renames.

- [ ] **Step 2: Ledger line and commit**

Append to `docs/dynide/status.md`:
`- 2026-10-25: renamed herdr-live to dynIDE (live/ -> dynide/, apps/crates/modules/env/paths -> dynide; herdr plugin env contract, vendored crates and herdr-reference unchanged); branch dynide-rename.`
Commit: `docs(status): record the dynide rename`.

- [ ] **Step 3: Stop the dogfood instance (user-confirmed)**

```bash
/Users/matt/herdr-project/herdr-live/live/bin/herdr-live status
pid=$(pgrep -f '^/Users/matt/herdr-project/herdr-live/live/native/herdr_broker/target/release/herdr_broker run')
kill -TERM "$pid"     # the broker itself, not tty_guard: clean stop, no handoff, session saved
```
Target only that pid. Other brokers on the host (release-check temp installs, other
worktrees) must keep running. Expected:
`pgrep -fl 'herdr-project/herdr-live/live/'` prints nothing.

- [ ] **Step 4: Fast-forward and clear untracked leftovers**

```bash
cd /Users/matt/herdr-project/herdr-live && git merge --ff-only dynide-rename
git ls-files live | wc -l        # must be 0
ls live                          # expect only _build deps native/*/target apps/*/priv/native leftovers
rm -rf live
```

- [ ] **Step 5: Move local state and find outside callers**

```bash
for d in "${XDG_CONFIG_HOME:-$HOME/.config}" "${XDG_STATE_HOME:-$HOME/.local/state}" "${XDG_CACHE_HOME:-$HOME/.cache}"; do
  [ -e "$d/herdr-live" ] && [ ! -e "$d/dynide" ] && mv "$d/herdr-live" "$d/dynide"; done
[ -e ~/.herdr-live ] && [ ! -e ~/.dynide ] && mv ~/.herdr-live ~/.dynide
mv "${XDG_STATE_HOME:-$HOME/.local/state}/dynide/herdr-live.log" "${XDG_STATE_HOME:-$HOME/.local/state}/dynide/dynide.log" 2>/dev/null
grep -rn -E 'herdr-live|HERDR_LIVE' ~/.claude/settings*.json ~/.zshrc ~/.zprofile ~/.config/dynide 2>/dev/null
```
Show the user every grep hit. Don't edit them without asking.

- [ ] **Step 6: Start and verify the session restored**

Run: `just dynide-run` (from the main checkout, in a fresh terminal).
Expected: the previous workspaces, tabs and scrollback come back, and
`dynide/bin/dynide status` answers. The log `~/.local/state/dynide/dynide.log` shows a
`dynide-event` restore line and no `session_lost`.

- [ ] **Step 7: Remove the worktree**

`git worktree remove ../herdr-live-worktrees/dynide-rename` (keep the branch).
