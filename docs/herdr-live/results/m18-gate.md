# M18 results: slice-1 gate table on the release build

The whole slice-1 table from [m6-gate.md](m6-gate.md), re-run once per OS at M18 on the
release build (R1: `MIX_ENV=prod`, hot reload off). M6's numbers are listed beside each
value. The M6 targets are used as restated by its (b) rulings (design.md "Slice 1").

## Environment and method

| | macOS | Linux |
|---|---|---|
| host | Apple M1 Max, 10 cores, 64 GB, Darwin 25.5 | podman machine `podman-machine-default` on the same Mac: 6 vCPU, 8 GiB, Linux 7.1.3-200.fc44 aarch64 |
| image / userland | OTP 29, Elixir 1.20.4, Rust 1.99, Zig 0.16.0 | `herdr-m18-check` (Ubuntu noble, same toolchain), `linux_check.sh` export of the worktree |
| commit | `15bea547` (clean) | `15bea547` (`dirty=1` comes from `git init` in the export, as in M6) |
| release | `scripts/release/build.sh` → `herdr-live-0.1.0-macos-aarch64.tar.gz`, `install.sh --prefix live/_build/gate-prefix` | same in the container → `herdr-live-0.1.0-linux-aarch64.tar.gz`, installed at `/work/live/_build/gate-prefix` |
| herdr reference | `bench/gate/herdr_ref.sh` (tag `herdr-reference` = `2be39ad9`, release build) | the same tag's `git archive`, built in the container with `cargo build --release --locked` (`HERDR_BIN`), since the export has no tags |
| load | 1-min load 4.8-18.8, CPU 63-71 % idle (`top`) at every suite boundary | guest load 2.3-17.7; host macOS idle 11-68 % (sampled every 20-30 s; drops to 11-18 % are the desktop's) |

Runs: `HERDR_LIVE_BIN=<prefix>/bin/herdr-live live/bench/gate_round.sh r1` (suites
`m3fake m3real m3real120 osfloor reload handoff glass herdrref`), then
`just live-bench-remote`. One suite at a time, nothing else of mine running. On Linux the same
sequence ran inside one `linux_check.sh` call. The flood suites (`m3real m3real120 osfloor`)
were then re-run once (r2) with `vmstat 5` in the guest, because guest CPU idle was not
recorded in r1. Logs (scratch, not committed): `.superpowers/sdd/m18/runs/gate-macos/` and
`gate-linux/{r1,r2}/`.

Build per row (the "build" column):

- **release**: the row drives the installed launcher (`HERDR_LIVE_BIN`, added to
  `bench/handoff/driver.exs`, `bench/remote/bench.exs` and `bench/gate/glass.py` in `15bea547`).
  The broker's VMs boot the release (`vm up 417 ms`, no Mix).
- **in-VM**: `MIX_ENV=test mix herdr.bench` from the umbrella root. The bench task and its
  fakes exist only in `:test`. The release's prod-only compile difference is consolidated
  protocols, and the umbrella root already consolidates in every env: the root `mix.exs`
  does not set `consolidate_protocols`, so it defaults to true. `_build/test/consolidated/` holds the same 8
  protocols as `_build/prod/consolidated/`, and in the bench VM `Protocol.consolidated?/1` is true
  for all of them (`Enumerable` loads from `_build/test/consolidated`). Reload is off in
  `:test` as in `:prod` (`config :herdr_reload, enabled: config_env() == :dev`).
- **dev**: reload rows. Reload is off in the release (R1), so they run on the dev build at the
  same commit.

## Slice-1 metrics table

| metric (design.md) | build | macOS M18 | macOS M6 (3 rounds) | Linux M18 | Linux M6 | target | verdict |
|---|---|---|---|---|---|---|---|
| keystroke → glass, idle, real pty (herdr-live vs herdr) | release | p95 695 µs vs herdr 436, **+259 µs** (load 6.3→4.8, 68-69 % idle) | +223 / +174 / +269 µs | p95 1073 µs vs herdr 974, **+99 µs** (guest 4.5→2.3, host 50-65 % idle) | +401 / +201 / +228 µs | ≤ herdr + 1 ms p95 | met |
| keystroke → glass, in-VM fake glass, fast / slow p95 | in-VM (real kernel) | 381 / 439 µs | 388-394 / 423-452 µs | 672 / 724 µs | 680-694 / 705-714 µs | (reference) | — |
| frame cost, 15 full panes, 120x40, full repaint | in-VM | 148 µs mean; herdr 666 µs | 162-175; herdr 652-689 | 201 / 201 µs (r1 / r2); herdr 750 µs | 177-183; herdr 726-755 | 15-pane full repaint ≤ herdr's at the same geometry | met |
| frame cost ratio 1 vs 15, 120x40 | in-VM | 4.32x (34 → 148 µs; herdr 1.11x) | 2.40-2.77x | 4.52x / 4.10x (44-49 → 201 µs; herdr 1.15x) | 2.31-3.07x | record (restated in M6) | recorded |
| frame cost at 200x50, 1 / 15 panes | in-VM | 46 / 204 µs (m3real), 42 / 200 µs (m3fake) | 58-68 / 307-326 | 57 / 251, r2 57 / 235 µs | 65-96 / 364-379 | (record) | — |
| 15-pane frame vs M7 (fake kernel, 200x50, mean / p95) | in-VM | 200 / 246 µs vs M7 338 / 379 (−41 %) | — | 230 / 276 µs | — | no > 10 % regression vs M7 | macOS met; Linux recorded (no M7 Linux baseline) |
| `cat` 100 MiB × 15: typing in a 16th pane | in-VM (real kernel) | p95 5.8 ms (200x50, max 13.3), 7.2 ms (120x40, max 15.2); load 5.1→10.8, 67-70 % idle | 7.2-7.6 ms (200x50; M6 gave one range, no 120x40 typing value) | r1 p95 13.0 / 11.4 ms (max 122 / 608); r2 10.1 / 12.9 ms (max 47 / 50); guest 2.4-4.1 | 11.4-12.0 ms (200x50, one range; max 69-622) | ≤ 20 ms p95 | met |
| `cat` 100 MiB × 15: scheduler stall (probe max) | in-VM (real kernel) | 9.4 ms (200x50), 10.9 ms (120x40) | 11.0-19.4 (120x40 11.3-16.3) | r1 99.7 / 110.6 ms; r2 79.8 / 90.5 ms | 41.6-81.3 (120x40 25.4-63.3) | no worse than the OS-only floor, ≤ 10 ms where it allows | macOS met; Linux met vs the floor's worst iteration (floor 7.9-592 ms over 6 iterations; see notes) |
| OS-only floor (BEAM probe next to 15 pty cats, no herdr) | none (script) | 47.0 / 38.8 / 48.7 ms (load 10.8→18.8, 70 % idle) | 61.1-92.1 | r1 7.9 / 484.8 / 8.4 ms; r2 591.8 / 194.1 / 294.2 ms | 340-699 | (floor) | — |
| edit `Client.Term.Render`, save → visible | dev (reload is off in the release, R1) | p95 220 ms (load 18.8→9.2, 65-67 % idle) | 288-296 | 223 ms | 282-296 | < 500 ms p95 | met |
| edit `View.compute`, save → visible | dev (R1) | 214 ms | 186-196 | 209 ms | 183-191 | < 500 ms p95 | met |
| add a field to `App.Ui` under load → visible | dev (R1) | 465 ms, fan-out 4 | 297-317, fan-out 3 | 477 ms, fan-out 4 | 294-300, fan-out 3 | < 1 s p95; record fan-out | met |
| add a field to `App.Session` → loaded | dev (R1) | 435 ms, fan-out 3 | 266-281, fan-out 2 | 442 ms, fan-out 3 | 276-280, fan-out 2 | record fan-out | recorded |
| add a field to a `Scene` struct → loaded | dev (R1) | 815 ms (median 568), fan-out per run 9-22 | 465-479, 3 + 1 | 870 ms (median 847), fan-out 10-22 | 472-502, 3 + 1 | record fan-out | recorded |
| infinite loop in `View.compute`, resize → frame | dev (R1) | 62.8 ms, no dropped resize | 62.0-64.1 | 69.3 ms | 67.9-71.5 | ≤ budget (50) + 100 ms | met |
| second reload of a module whose closure is in state | dev (R1) | rejected in 0.9 ms p95 (median 0.5), pids unchanged | 0.3-0.5 | 1.6 ms (median 0.5) | 0.4-0.5 | rejected with a message | met |
| rollback after a pane spawned in the window | dev (R1) | 14.6 ms; adopted, all mapped, no orphans | 7.9-13.5 | 14.2 ms; same checks | 9.3-13.3 | reconciled | met |
| reload while `cat` runs in 15 panes (real kernel) | dev (R1) | save → visible 553 ms p95 (median 511) | 429-463 | 1907 ms (median 1103) | 907-1423 | measure | recorded |
| `kill -9` the VM with 15 shells, ready standby | release | p50 36, p95 39, max 46 ms (12 runs); every run 15/15 alive, 5/5 answered, scrollback, htop (load 9.2→7.1, 66-68 % idle) | p50 36-37, p95 42, max 48 | p50 50, p95 54, max 55 ms (12 runs); all checks pass (guest 7.6→4.8, host 50-64 % idle) | p50 54-59, p95 63 | < 1 s p95 | met |
| `kill -9` with no ready standby (cold) | release | 519 ms | 671-676 | 564 ms | 661-706 | (report separately) | under 1 s |
| graceful `kernel-restart` during typing | release | 1600/1600 bytes, window 5 ms, restart 494 ms | 1600/1600, 8-12 ms | 1600/1600, window 4 ms, restart 480 ms | 1600/1600, 7-9 ms | no loss | met |
| second client at a different size: in-VM client over the client protocol | in-VM (real kernel) | p95 337 µs (200x50 + 80x24), 420 µs (120x40 + 80x24) | 321-355, 334-368 | 611 / 640 µs | 596-620, 629-653 | both render; typing in one visible in the other | met |
| second client over the client socket (M16, another OS process) | release | unix p95 0.67 ms, relay 0.71 ms; under a 15-pane flood p95 13.5 / 15.0 ms (load 4.9→13.8, 63-65 % idle) | — (M16) | unix 1.01, relay 1.17 ms; flood 19.2 / 20.7 ms (max 25 / 122; guest 2.7→17.7) | — | (M16 record) | recorded |

## Notes

- **Glass** runs the M6 method unchanged (`glass.py`, 200x50, `exec cat`, n=500). On macOS
  herdr-live is 30 µs slower than M6's worst round in this one run. Its max is 1.2 ms, against
  herdr's 8.9 ms. On Linux the delta is the smallest yet.
- **Frame ratio.** The 1-pane frame got cheaper since M6 (120x40: about 60 → 34 µs macOS),
  and the 15-pane frame got cheaper too (162-175 → 148 µs). The ratio therefore grew, while the
  restated target (15 panes ≤ herdr) holds with 4.5x (macOS) and 3.7x (Linux) margin.
- **Linux stall.** Both rounds are below the floor's worst iteration, as M6 judged the restated row
  (r1 100-111 ms against 485 ms; r2 80-91 ms against 592 ms). The floor's full range over
  its six iterations is 7.9-592 ms (r1 7.9 / 484.8 / 8.4, r2 591.8 / 194.1 / 294.2), so the
  stall is above the floor's best iterations. Linux is above M6's
  25-81 ms. The floor is bimodal today: in r1 two of its three iterations stayed under 9 ms.
  Guest idle during the floods was 4-49 % (vmstat), between floods 97-99 %, and the host
  dipped to 11-18 % idle in the same minutes. In r1 the long-schedule events (80, max 83 ms, in
  `Render` waiting on the guard's compose worker, and `Pane.Server`) dropped to 7 (max 9 ms)
  in r2 with the same code. That points to vCPU preemption, not BEAM work. The ≤ 10 ms clause is
  not reachable where the floor itself reaches 194-592 ms.
- **Reload fan-out growth.** M6 → M18 the `App.Ui` field reload grew from about 300 to
  465-477 ms (fan-out 3 → 4) and `App.Session` from about 280 to 435-442 ms (fan-out 2 → 3).
  The `Scene` struct field went from 465-502 to 815-870 ms p95, because M7-M17 added modules that build
  scene structs (per-run fan-out 9-22). Linux shows the same numbers at guest load 4-8, so
  this is real growth, not load. Every targeted row is still met: `App.Ui` is at 47 % of 1 s,
  and the other two are "record". `just live-bench-reload` exited 0 on both OSes.
- **cat15 on Linux** (1.9 s p95) is the Mix compile next to 15 floods in a 6-vCPU guest, as M6
  noted (0.9-1.4 s). It is a "measure" row.
- **Socket second client.** M6 could only run the in-VM client. M16's transport now lets
  `bench/remote/bench.exs` attach a separate OS process to the installed release. Both forms are
  listed. The Linux relay max of 122 ms came under the flood at guest load 17.7.

## Rulings

- Ruling: the in-VM microbenches run `MIX_ENV=test mix herdr.bench` from the umbrella root
  rather than inside the release. Why: the task and its fakes exist only in `:test`, and the
  release's compile-time difference (protocol consolidation) is already active there, checked
  as listed above. Reload is off in both. Evidence (macOS, M18): from `live/`, in `MIX_ENV=test`,
  `Protocol.consolidated?/1` is true for `Enumerable` and `String.Chars`. No protocol on the
  code path is left unconsolidated, and `Enumerable` loads from
  `live/_build/test/consolidated/`, which holds the `Collectable`, `Enumerable`, `IEx.Info`,
  `Inspect`, `Jason.Encoder`, `JSON.Encoder`, `List.Chars` and `String.Chars` beams. Run from
  `live/apps/herdr_term`, the same check gives false. So the benches must run from the
  umbrella root, which `gate_round.sh` does (`cd live`). Cost if wrong: an unseen prod-only compile effect on
  Compose/Render, which would have to come from `Mix.env()`-conditional code on the render path.
  None exists today.
- Ruling: Linux herdr is built in the container from the `herdr-reference` tag's `git archive`
  (`HERDR_BIN`), not by `herdr_ref.sh`. Why: the export has no git history or tags. Cost if
  wrong: none; it is the same source and toolchain.
- Ruling: the Linux stall row is met under M6's restated (b) target, with no new work. Why: it
  stayed below the measured OS floor in both rounds, and the r1/r2 spread (long-schedule events
  80 → 7 on the same code) is host contention. Cost if wrong: a Linux scheduler regression of
  up to about 30 ms over M6 is hidden in VM noise. The next Linux check is bare-metal Linux
  (still a known gap).
- Ruling: one round per OS (M6 ran three), with one extra Linux flood round. Why: the brief asks for
  one per OS, and no row missed. Cost if wrong: the tails are single samples.

## Known gaps

- Linux is aarch64 in a VM on the same Mac; x86_64 and bare-metal Linux were not run.
- r1 on Linux recorded guest load but not guest CPU idle. The host's idle was sampled from the
  reload suite onward, and r2 repeated the flood rows with `vmstat`.
