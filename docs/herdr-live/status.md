# herdr-live: coordination ledger

Program-level ledger for implementing [milestones.md](milestones.md). This is
the recovery map for the coordinating session: trust this file and
`git log` over memory.

## Operating model

- One coordinator session owns this file and the `herdr-live` integration
  branch. It never pushes.
- Each milestone has one owner agent (Opus 5.5). The owner plans the
  milestone into tasks (superpowers:writing-plans), executes them with
  implementer and reviewer subagents (superpowers:subagent-driven-development),
  and reports back with the exit-criteria evidence.
- Milestone work happens on branch `live/m<N>` in worktree
  `../herdr-live-worktrees/m<N>`, branched from the current `herdr-live`.
  The owner commits there freely without asking (the human authorized
  autonomous implementation). The coordinator reviews the exit-criteria
  evidence, merges into `herdr-live`, and removes the worktree.
- Parallel owners rebase on `herdr-live` when a sibling lands, before their
  own merge.
- Human decision points: the M6 gate ADR, the M7 dogfooding week, the M15
  GUI technology ADR. Everything else proceeds without asking.
- Results go in `docs/herdr-live/results/m<N>.md` on the milestone branch.

## Environment

- Host: macOS (Darwin 25.5), 10 cores, 64 GB.
- Rust 1.99, Zig present, `just` 1.58, Homebrew present.
- Erlang/OTP 29 and Elixir 1.20.4 installed via Homebrew by the coordinator at the
  start of M0 (2026-10-23).

## Milestone status

| milestone | status | branch | owner | merged at | notes |
|---|---|---|---|---|---|
| M0 skeleton | merged | (deleted) | agent | 179cd23e | 15 commits; results/m0.md; live-check verified green by coordinator |
| M1 kernel vt+pty | merged | live/m1 | agent | 95ace52e | 25 commits; results/m1.md; 56 cargo + 26 ExUnit; mode/2 p999 1µs under cat 100MB; live-check verified green |
| M2 term kernel tty+blit | merged | live/m2 | agent | 4ce76654 | 16 commits; results/m2.md; green on macOS and Linux (podman); manual GUI-terminal check owed by human (steps in results/m2.md) |
| M3 server core + term client | merged | live/m3 | agent | 1474b6df | 43 commits; results/m3.md; 181/78/51 tests + integration + real_kernel; both kernel swaps done; prefix follow-up merged at 0c773657 |
| M4 reload + rollback | merged | (deleted) | agent | be57f9ff | phase 1 at 54093015; phase 2: 16 commits, results/m4.md; all slice-1 reload targets met (render p95 462ms, view 371ms, ui_field@15 panes 759ms, view_loop 72ms, cat15 588ms); tests 51/80/84/160/11+5; live-check verified green by coordinator |
| M5 kernel restart | merged | (deleted) | agent | 09672219 | 31 commits; results/m5.md; kill -9 @15 panes warm p50 58-66ms, nearest-rank p95 148ms over 48 runs (one 1085ms outlier), cold 1.0-1.1s; typing through kernel-restart 1600/1600 bytes; standby 127MB RSS; Linux never compiled (podman wedged); live-check verified green by coordinator |
| M6 gate | done: GO with changes | (deleted) | agent | 0ab8cc5a | 27 commits; results/m6-gate.md; adr/0001 accepted by the human 2026-10-24; 15 rows met on macOS and Linux, 2 restated (frame ratio, flood stall); live-check verified green by coordinator |
| M7 self-hosting | not started | | | | human dogfood week |
| M8 persistence | not started | | | | |
| M9 terminal fidelity | not started | | | | |
| M10 kitty graphics | not started | | | | |
| M11 detection | not started | | | | |
| M12 API + CLI | not started | | | | |
| M13 chrome + UX | not started | | | | |
| M14 plugins | not started | | | | |
| M15 GUI client | not started | | | | human ADR |
| M16 remote attach | not started | | | | |
| M17 long tail | not started | | | | |
| M18 release | not started | | | | |

## Log

- 2026-10-23: ledger created; Erlang/Elixir install started; M0 owner dispatched.
- 2026-10-23: M0 DONE_WITH_CONCERNS at 179cd23e; coordinator re-ran `just live-check` on merged tree: exit 0. Fast-forwarded into herdr-live. Concerns carried: Linux CI never executed (no push); the M0 owner's Linux subagent added a 6 GiB swapfile at /var/tmp/swapf inside the podman VM and left a `herdr-linux-check` image.
- 2026-10-23: wave 1 dispatched: M1, M2, M3, M4-prep owners on live/m1..m4 from 179cd23e.
- 2026-10-23: M1 SPEC_PUBLISHED at 03846db6 (HerdrScene.Cell: 32-byte LE records, per-row trailer for long clusters, 15 golden vectors from an independent Python encoder, docs/herdr-live/packed-cells.md). Merged into herdr-live; herdr_scene 21 tests pass. M1 resumed for phase 2; M2 and M3 told to rebase.
- 2026-10-23: M4 phase 1 DONE_WITH_CONCERNS at 94d87b18; merged (no conflicts) as 54093015. Guard signature `Reload.Guard.run(mod, fun, args, opts) :: {:ok, term} | {:failed, failure}`; failures `{:raise|:throw|:exit, _, st}`, `{:timeout, ms, st}`, `{:local_fun, mod, path}`; opts `budget_ms`, `server`, `scan`. Guard cost: 0.13µs inline, 4µs with a budget on small args; local-fun scan is O(state) (349µs on 1.6MB) so phase 2 must scope it. Concerns carried to phase 2: (a) a rolled-back module's bad beam stays on disk and would autoload later — rollback must restore the previous beam on disk too; (b) receive loops on old code block reloads — fully-qualified loop calls or allowlist; (c) Watcher untested on Linux (needs inotify-tools). A stray erl_crash.dump ("device does not exist" during boot, stderr closed) appeared at the herdr-live root at 17:52 during a live-check run; cause unconfirmed, likely a smoke child; verify when M3 lands.
- 2026-10-23: coordinator's live-check on the merged tree (M0 + M1 spec + M4 phase 1) green; no crash dump produced.
- 2026-10-23: M2 handed back early and incomplete (no results, no final review, two Linux failures: ttyname static buffer in a test helper; tty not cooked while suspended on Linux). Resumed with a finish-list. Not merged.
- 2026-10-23: M1, M2, M3 owners all terminated by an API rate limit; resumed from their saved state once lifted. M3 told to rebase onto 33a8a6b4 (M4 phase 1 present).
- 2026-10-23: M1 DONE_WITH_CONCERNS at 7a32cf4c; merged as 95ace52e with one conflict (application.ex: Keeper first, then Reload.Supervisor). live-check green. Carried: SIGCHLD reset to default at NIF load is process-wide (M5/M18 informed); x86_64 Linux unrun; final drain after exit can drop background-job output on Linux; hyperlink id table grows for pane lifetime; Keeper crash during the 2s close window leaves a child with only HUP. M3 informed of the real kernel API and told to rebase.
- 2026-10-23: M5 dispatched (kernel restart under live children) from 95ace52e.
- 2026-10-23: M2 DONE_WITH_CONCERNS at 6f7e05e3; merged as 4ce76654 (conflict: live/mix.exs dialyzer plt_add_apps, kept :mix and :ex_unit). Linux root causes fixed: ttyname -> ttyname_r in the test helper; Linux-only raise(SIGSTOP) after kill(0, SIGSTOP) returns early. Owed to human: manual live-demo check in a real GUI terminal. Leftovers outside repo: podman image localhost/herdr-m2-check. M3 and M5 informed (Tty/Blit API; stty wrapper belongs in the broker).
- 2026-10-23: M3 DONE_WITH_CONCERNS at 1474b6df; fast-forwarded. Bench (real kernel, bench client on fake tty): keystroke→glass p95 361µs fast / 424µs slow; frame 80µs @1 pane, 638µs @15 (7.9×); 15×100MiB cat: probe stall max 95ms (target 10ms — gate item), typing p95 12.8ms. Owed to human: GUI-terminal run (procedure in results/m3.md). Known gaps: local client crash not restarted; Pane.Rows restart loses id map (→ M4 ph2). Deviations for M1: pastes >1MiB truncate (needs per-pane retrying write queue); encoders reject some mods; fallback key tables unported. M4 phase 2 started; M5 informed (tty_guard.sh, Client.Session as handoff consumer).
- 2026-10-23: live-check green on herdr-live with M3. M3 prefix follow-up DONE at 0c773657 (mode moved to Client.State; new additive protocol message {:input_mode, mode}; two-client test fails on old code); fast-forwarded; design.md and AGENTS.md state-layout text corrected.
- 2026-10-24: M4 phase 2 DONE_WITH_CONCERNS at be57f9ff; fast-forwarded after coordinator live-check (exit 0, no crash dump). New app `herdr_reload` holds the whole reloader (`HerdrReload.*`); `safe_apply` replaced by `HerdrReload.Guard.run_twice/4` (re-run only after an attributed rollback; the re-run never attributes); `HerdrServer.Mirror` owns the ETS tables; rollback restores beams on disk, bad beams kept under `<build>/herdr_reload/rejected/`; `herdr-live rollback [n]` over a dev-only control socket (stopgap until M12). The bench found and fixed four reload bugs with regression tests: touch-triggered perpetual reload loop (now content-unchanged → :noop); failures during Mix's compile window blamed the batch that had just loaded (failure timestamp attribution); the re-run after a rollback blamed an innocent older batch; the first same-second edit after start was missed. Provisional pre-fix numbers (render p95 6.6s, view_loop p95 805ms) were bug 1 contamination. Carried: Store `:kill` inside its 20ms debounce loses that window's focus/mode/tab writes; after a rollback only a content change reloads the source; client mirror entry leaks after a session crash; notice width counts chars not cells (M16); store.ex ~485 lines (split in M7); stall test fails under host load ~21 (podman VM from a sibling owner); local-client crash restart deferred to M7; hangs inside `Actions.apply`/Store are unbudgeted. AGENTS.md "Adding an app" updated for the herdr_reload dependency rule (confirmed). M5 told to rebase.
- 2026-10-24: M5 DONE_WITH_CONCERNS at bb777398; rebased by coordinator onto d7d721c9 (09672219) and fast-forwarded after live-check (exit 0; tests 51/80/88/201/11+5, cargo 11/79/52/16). Rust broker `live/native/herdr_broker` plus `herdr_fdpass`; the VM learns FRESH/ADOPT over the link; one warm standby (~127MB); ghostty snapshot format carries screens every 1s (crash loses ≤1s of history, graceful exact); pane ids preserved; adopted children report exit `:unknown`; broker absorbs tty_guard for bin/herdr-live; control socket and reload pipeline move with the primary. Handoff contract `{:handoff, %{phase, gen, panes}}` implemented in Client.Session and herdr_term. 31 rulings in results/m5.md, accepted. Carried to M6: Linux paths (exitwatch pidfd, link.rs, broker) never compiled; cold handoff 1.0-1.1s over target under load ~20; one unexplained 1085ms warm kill-9; StallTest flakes at load >25; promoted standby runs boot-time code (edits between standby boot and promotion load only on next change). Carried to M8: adopted exit status, broker as reaper, `fallback_restore` stub. An M5 implementer killed every `sleep 30` on the host during cleanup (may have hit sibling tests). Podman machine wedged ~10h; coordinator restarting it for M6. AGENTS.md repo-layout and hot-reload sections updated for the broker, new crates, and handoff contract.

- 2026-10-24: M6 gate owner dispatched from b46e4425. Coordinator restarted the wedged podman machine (stale krunkit from 18 days ago survived `machine stop`; killed it) and resized it to 6 CPUs / 8 GiB so the Linux build no longer needs the swapfile hack.
- 2026-10-24: M6 DONE_WITH_CONCERNS at 0ab8cc5a; fast-forwarded after live-check (exit 0; 51/81/89/201/11+5, cargo 11/85/52/16, handoff smoke ok). Table run 3x on macOS (M1 Max, loaded desktop) and 3x on Linux (aarch64 podman). Met: keystroke hop +0.2-0.4ms over herdr; 15-pane repaint 162-183µs vs herdr 652-755µs; all reload rows (render 296ms, view 196ms, ui_field 317ms, loop 64-72ms); kill -9 warm p95 42/63ms, cold 661-706ms; typing through restart 1600/1600; second client correct. Missed as written and restated in design.md as (b): frame ratio 1 vs 15 (2.3-3.1x; now judged by absolute cost vs herdr) and flood scheduler stall (11-19ms macOS, 25-81ms Linux; now judged against the OS-only floor, which is 61-699ms). (a) fixes: Compose row-major segments (15 panes 640→307-379µs); compose-helper NIF prototyped, no gain, reverted; flooding PTY readers demoted (macOS utility QoS, Linux nice 10); scrollback lost after ~18 handoffs fixed by vendored ghostty patch 0008 (indexed, maintenance-test passes); promoted standby now loads beams changed on disk (ruling 28 closed, macOS-measured only); StallTest control duration-matched (test was at fault); 1085ms outlier did not recur in 264 runs. Linux bring-up needed only test and bench fixes; M5 Linux paths compiled clean. Concerns: tails are upper bounds (busy desktop); Linux typing max under flood 69-622ms; no bare-metal or x86_64 Linux; demoted Linux reader keeps nice 10 for the pane's life; stale herdr_term.so after the NIF revert needed `mix compile --force`. Leftovers: podman image herdr-m6-check, volumes herdr-m6-cargo/herdr-m6-hex. Coordinator stopped here for the human's go/no-go on adr/0001.
- 2026-10-24 (human): adr/0001 accepted, go with changes. M7 unblocked; owner dispatched with the ADR's four 'M7 first' items.
## Rulings

Decisions the coordinator made on the human's behalf, newest last, each with
what it costs if wrong.

- 2026-10-23: Milestone owners commit on their branches without proposing
  messages first. The repo's "propose the commit message" rule is for
  interactive work; the human asked for autonomous coordination. Cost if
  wrong: commit messages to tidy before any push.
- 2026-10-23: Coordinator merges milestone branches into `herdr-live`
  without asking, once exit criteria are evidenced. `herdr-live` is a local
  integration branch, not `master`, and is never pushed by the coordinator.
  Cost if wrong: a local branch to reset.
- 2026-10-23: M1 delivers in two phases: packed cell spec (HerdrScene.Cell,
  golden vectors, docs/herdr-live/packed-cells.md) first, then stops; the
  coordinator merges that commit into herdr-live and tells M2/M3 to rebase,
  then resumes M1. Cost if wrong: M2/M3 idle on cell decoding for an hour.
- 2026-10-23: M3 adds `HERDR_LIVE_HEADLESS=1` so the launcher smoke keeps
  passing once Tty.Owner exists. Cost if wrong: a flag to rename.
- 2026-10-23: M3 may add a test-only umbrella app `herdr_integration` that
  depends on both herdr_server and herdr_term, exempted by name in the
  dependency-rule test. Cost if wrong: one app to delete.
- 2026-10-23: M2's live-demo runs against a fake row source; real M1 wiring
  happens after both land. Cost if wrong: a demo to rewire.
- 2026-10-23: Prefix mode and pending-key state are per-client (Client.State),
  like tmux per-client key tables; the modal stack stays shared until M13
  decides. Implemented as follow-up branch live/m3-prefix. Cost if wrong: a
  field to move back.
- 2026-10-23: Reload machinery shared by server and client moves to a new
  umbrella app `herdr_reload` (depends only on herdr_scene); the dependency
  rule becomes "herdr_scene plus optionally herdr_reload". Cost if wrong: an
  app to fold back into herdr_server.
- 2026-10-23: Rollback restores the previous .beam on disk as well as in
  memory, keeping the bad beam inspectable. Cost if wrong: disk churn.
- 2026-10-24: M4 phase 2 rulings accepted as written in results/m4.md:
  `Guard.run_twice` re-runs only after an attributed rollback and never
  attributes the re-run; a 50ms budget only on `View.compute` and
  `Compose.screen`; `Server.fail/4` blames only batches loaded at or before
  the failure time; unchanged file content is a `:noop` reload; a logic-free
  `HerdrServer.Mirror` owns the ETS tables; the dev-only control socket is a
  stopgap until M12; local-client crash restart deferred to M7. Cost if
  wrong: one of these becomes an M6 gate finding.
- 2026-10-24 (human): M14 ports only herdr's existing external-process
  plugin model; BEAM plugins are out of scope. Cost if wrong: a later
  milestone adds an in-VM plugin path beside the external one.
