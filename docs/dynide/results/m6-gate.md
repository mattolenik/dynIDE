# M6 results: slice-1 gate

Branch `live/m6` from `herdr-live` at `478a49cb` (M0-M5 merged, `b46e4425`, plus the
coordinator's dispatch note). Plan: [plans/m6.md](../plans/m6.md). Proposed decision:
[adr/0001-slice-1-gate.md](../adr/0001-slice-1-gate.md). The decision is the human's.

## Environment

| | macOS | Linux |
|---|---|---|
| host | Apple M1 Max, 10 cores, 64 GB, Darwin 25.5 (macOS 26.5) | podman machine `podman-machine-default` (libkrun) on the same Mac: 6 vCPU, 8 GiB, Linux 7.1.3-200.fc44 aarch64 |
| userland | Erlang/OTP 29 (erts 17.1.1), Elixir 1.20.4, Rust 1.99, Zig 0.16.0 | image `localhost/herdr-m6-check` (from `herdr-m2-check`: Ubuntu noble, same OTP/Elixir/Zig, plus htop, inotify-tools, procps, rsync), container runs as root, `/bin/sh` is dash |
| gate commit | `dc9267df` (the later `6d870c38` changes only harness cleanup in `bench/gate/glass.py`, outside the timed window) | `6d870c38` |
| load during the 3 gate rounds | load average 6-13, CPU 62-75 % idle (`top`); a shared desktop (Firefox, Godot, Unity, WindowServer, Spotlight) | guest load average 1.5-7.6; the macOS host was the same desktop |
| tree | the worktree itself | `git archive HEAD` export copied into the container (`dynide/scripts/linux_check.sh`), separate `_build`/`target` |

Linux run env lines show `dirty=1`; that is an artifact of `git init` in the container
(the export has no history), not a modified tree.

The host was not quiet earlier in the day: macOS load average sat at 40-200 with
50-60 % CPU idle (mostly blocked Spotlight threads). The three gate rounds per OS ran
after it settled. On macOS the load average is a poor quietness signal, so every suite
also records CPU idle. Every suite line in `.superpowers/sdd/m6/runs/<os>-r<n>/summary.txt`
carries load at start and end; those logs are not committed (scratch), the numbers
below are copied from them.

How each round ran: `dynide/bench/gate_round.sh r<n>` runs, one after another, never in
parallel with anything else: `mix herdr.bench` (fake kernel), `mix herdr.bench --kernel
real` (200x50), the same at `--size 120x40`, `just live-bench-reload`,
`just live-bench-handoff`, `just live-bench-glass`, and herdr's own
`render_scale_profile` (release). The podman machine did not wedge in M6.

## Slice-1 metrics table

Per-run values are listed run 1 / run 2 / run 3. "p95" for 10-iteration reload
scenarios is nearest rank (= the max). Kill -9 p95 is nearest rank over the 36 warm runs
of the three rounds.

| metric (design.md) | macOS | Linux | target | verdict |
|---|---|---|---|---|
| keystroke → glass, idle, through a real pty (herdr-live vs herdr) | herdr-live p95 690 / 599 / 736 µs; herdr 467 / 425 / 467 µs; delta +223 / +174 / +269 µs | herdr-live 1347 / 1160 / 1299 µs; herdr 946 / 959 / 1071 µs; delta +401 / +201 / +228 µs | ≤ herdr + 1 ms p95 | met |
| keystroke → glass, in-VM fake glass (M3 bench, fast / slow path p95) | 388 / 377 / 394 µs; 423 / 452 / 427 µs | 694 / 685 / 680 µs; 705 / 714 / 714 µs | (reference) | — |
| frame cost, 15 full panes, 120x40 (herdr's profile geometry), full repaint | 167 / 175 / 162 µs mean; herdr 652 / 677 / 689 µs | 177 / 177 / 183 µs; herdr 755 / 726 / 750 µs | **(b)** 15-pane full repaint ≤ herdr's at the same geometry | met |
| frame cost ratio 1 vs 15, 120x40 | 2.77 / 2.77 / 2.40x (herdr 1.13 / 1.15 / 1.18x) | 2.31 / 3.07 / 2.78x (herdr 1.14 / 1.12 / 1.12x) | was: within 2x herdr's ratio (≤ 2.24-2.36x) | missed as written; restated (b) |
| frame cost at 200x50, 1 / 15 panes | 59 / 58 / 68 and 318 / 326 / 307 µs (4.5-5.6x) | 75 / 65 / 96 and 364 / 371 / 379 µs (3.9-5.7x) | (record) | — |
| `cat` 100 MiB in 15 panes: typing in a 16th pane | p95 7.6 / 7.4 / 7.2 ms (max 23 / 19 / 17) | p95 11.4 / 12.0 / 11.6 ms (max 209 / 69 / 622) | ≤ 20 ms p95 (the original row gave no percentile; judged at p95 as M3 did, M6 gate change) | met (p95; max values shown) |
| `cat` 100 MiB in 15 panes: scheduler stall (`Process.sleep(1)` probe max overshoot) | 19.4 / 11.0 / 11.9 ms (120x40 runs: 16.3 / 11.3 / 15.1) | 41.6 / 60.6 / 81.3 ms (120x40 runs: 63.3 / 53.1 / 25.4) | was: no stall > 10 ms | missed as written on both OSes; below the OS-only floor on both, see (b) |
| OS-only floor: BEAM probe next to 15 pty `cat`s of 100 MiB, no herdr code | 92.1 / 61.1 / 91.2 ms | 451 / 340 / 699 ms | **(b)** stall no worse than this floor, ≤ 10 ms where the floor allows | met |
| edit `Client.Term.Render`, save → visible | 288 / 291 / 296 ms | 289 / 282 / 296 ms | < 500 ms p95 | met |
| edit `View.compute`, save → visible | 186 / 192 / 196 ms | 184 / 191 / 183 ms | < 500 ms p95 | met |
| add a field to `App.Ui` under load → visible | 317 / 302 / 297 ms, fan-out 3 | 300 / 297 / 294 ms, fan-out 3 | < 1 s p95; record fan-out | met |
| add a field to `App.Session` | 266 / 281 / 281 ms to loaded, fan-out 2 | 277 / 276 / 280 ms, fan-out 2 | record fan-out | recorded |
| add a field to a `Scene` struct | 479 / 474 / 465 ms to loaded, fan-out 3 + 1 (herdr_scene, herdr_server, herdr_term) | 479 / 472 / 502 ms, fan-out 3 + 1 | record fan-out | recorded |
| infinite loop in `View.compute` | resize → frame 62.0 / 64.1 / 62.3 ms, no dropped resize | 68.9 / 67.9 / 71.5 ms | ≤ budget (50) + 100 ms | met |
| second reload of a module whose closure is in state | rejected in 0.4 / 0.3 / 0.5 ms, no killed process | 0.4 / 0.5 / 0.4 ms | rejected with a message | met |
| rollback after a pane spawned in the window | restored in 13.5 / 7.9 / 8.6 ms; adopted, nothing orphaned | 9.6 / 13.3 / 9.3 ms | reconciled | met |
| reload while `cat` runs in 15 panes (real kernel) | save → visible 453 / 463 / 429 ms | 1258 / 907 / 1423 ms | measure | recorded |
| `kill -9` the VM with 15 shells, ready standby | p50 36-37 ms, p95 42 ms, max 48 ms (36 runs); every run 15/15 alive, 5/5 answered, 5/5 scrollback, 5/5 htop | p50 54-59 ms, p95 63 ms, max 63 ms (36 runs); same checks all pass | < 1 s p95 | met |
| `kill -9` with no ready standby (cold) | 671 / 676 / 673 ms | 694 / 706 / 661 ms | (report separately) | under 1 s |
| graceful `kernel-restart` during typing | 1600/1600 bytes, window 9 / 8 / 12 ms | 1600/1600, window 8 / 9 / 7 ms | no loss | met |
| second terminal client at a different size | typing in A visible in B: p95 321 / 355 / 354 µs (200x50 + 80x24), 368 / 334 / 344 µs (120x40 + 80x24); real-kernel two-client test passes | p95 602 / 596 / 620 µs; 629 / 648 / 653 µs; test passes | both render correctly; typing in one visible in the other | met (in-VM client over the client protocol; see notes) |
| kill -9 after many handoffs: scrollback kept (found in M6) | 30 consecutive handoffs, 5/5 every run | 3 sessions of 12 handoffs (below the ~18-handoff point), 5/5 every run; the 30-handoff check ran on macOS only | scrollback restored | met after fix (a) |
| promoted standby runs current code (ruling 28, found in M5) | edit before kill -9 live in the new primary 3/3 (68-235 ms after the kill) | — (macOS run) | edits survive a crash | met after fix (a) |

Notes on the table:

- **Glass.** `dynide/bench/gate/glass.py` spawns each program as the session leader of a
  200x50 pty with `exec cat` in its one pane, waits 30 ms of output silence, writes one
  letter to the master, and stops the clock at the first output chunk that contains it
  once escape sequences are stripped. Probe replies are outside the timed window. Same
  method, same pty, same machine for both. herdr runs from `target/release/herdr` with
  an isolated XDG dir and `onboarding = false`.
- **Frame cost.** herdr-live: `Compose.frame/3` + `Fake.Blit.frame/3`, 15 full panes,
  full repaint, mean of 200. herdr: `render_scale_profile` "active panes (one
  workspace)" combined pipeline (server pane surface + client shell composition),
  median of 40, at its fixed 120x40. The scopes differ: herdr's figure also builds the
  pane surfaces from terminal state, while herdr-live's starts from packed rows the
  kernel already produced and excludes `View.compute` (scene) and the row fetch, so
  the absolute comparison favours herdr-live by construction; the ratio does not
  depend on that. The herdr-live 1-pane frame has no border (one segment per row), so
  its ratio compares about 50 assembled segments with about 1045 (see "Misses").
- **Flood.** `herdr.bench --kernel real`: 16 panes at 200x50 (or 120x40), 15 `cat` a
  100 MiB file, a 16th takes typing; the probe is a BEAM process looping
  `Process.sleep(1)`. The OS-only floor uses the same probe next to 15 `script(1)` pty
  cats of a 100 MiB file with no herdr process running: `dynide/bench/gate/os_floor.sh` (probe
  `os_floor.exs`; macOS `script -q /dev/null cat F`, Linux `script -q -c "cat F" /dev/null`;
  `just live-bench-os-floor`, suite `osfloor` of `gate_round.sh`). Typing is judged at p95
  (max 23 / 19 / 17 ms macOS; 209 / 69 / 622 ms Linux, where p95 holds but the max does not).
- **Second client.** The second client is an in-VM terminal client on a fake tty that
  attaches over the client protocol (`Client.Session`), as M3 did. A second real
  terminal window in another OS process needs the M16 transport. While B is attached the
  latest active client drives the pane size, so A's pane runs at B's size during that row.
- **Reload under flood** (`cat15`) is slow on Linux (0.9-1.4 s): the 6-vCPU VM runs the
  Mix compile next to 15 floods. The target is "measure".

## Misses and what was done

Each miss: root cause, then exactly one of (a) bounded fix with a regression test and
re-measure, (b) design change written into design.md and listed in the ADR, (c) no-go.

### 1. Frame cost ratio 1 vs 15 (b), with an (a) fix kept

- Before M6: 1 pane 80 µs, 15 panes 640 µs at 200x50 (8x); herdr 1.14x. Target ≤ 2.28x.
- Root cause (`:tprof`, Task 6): per-segment Elixir overhead, not bytes. A 15-pane frame
  assembles about 1045 segments (left border, content, right border per pane row, plus
  status) against 50 for the borderless 1-pane frame, copying about the same 320 KB.
  The largest single cost was the wide-character check in `Cells.text` dispatching the
  Enumerable protocol (protocols are unconsolidated in dev and test); borders were
  re-encoded every frame; footers were read about 3400 times per frame; every row walked
  every pane.
- (a) `8ee4e7b8`, `996e8ee0`: guard-clause wide check, per-frame border cache, exact-width
  rows skip `fit`, one footer read per piece, row-major segment build. Output is
  byte-identical (a 15-pane grid digest captured from the old code, plus the existing
  compose tests). 15 panes at 200x50: 640 → 307-379 µs; at 120x40: about 430 → 162-183 µs.
- Compose-helper NIF prototype (design.md's named fallback), `15f728d4`: a policy-free
  row assembler in `herdr_term` (segments in, packed rows out, trailers handled). Its
  call costs 26 µs (1 pane) and 71-76 µs (15 panes) at 200x50, but Elixir still builds
  the same 1045 segment terms, so 15-pane frames were 333-383 µs against 350 µs for the
  Elixir fix. No gain; reverted in `a166dcd8` (history keeps it). The next lever, if
  per-segment work grows (overlays, graphics), is a NIF that places whole pane
  rectangles, so Elixir builds one term per pane.
- Ratio after the fix: 2.4-2.8x macOS, 2.3-3.1x Linux at 120x40, still over 2x herdr's.
  In absolute terms herdr-live's 15-pane full repaint is about 4x cheaper than herdr's
  at the same geometry (and its 1-pane frame about 9x cheaper), which is the cost the
  ratio was a proxy for. Frame scope differs: herdr's figure also builds pane surfaces;
  herdr-live's starts from kernel-packed rows and excludes `View.compute` and the row
  fetch. The remaining ratio miss is Elixir per-segment cost, the composition risk
  design.md names, measured and bounded.
- (b) design.md row restated: "15-pane full repaint ≤ herdr's at the same geometry;
  record the 1 vs 15 ratio".

### 2. Scheduler stall under the 15-pane cat flood (a) then (b)

- Before M6: probe max 78-95 ms (M3), 77-132 ms macOS and 217-1121 ms Linux in M6's
  first rounds; long schedules up to 50 ms (macOS) and 711 ms (Linux) in plain
  `Pane.Server`/`Render` processes.
- Root cause (Task 4c): OS CPU contention preempting BEAM scheduler threads, not BEAM
  work. A BEAM probe stalls the same way next to 15 plain pty cats with no herdr code at
  all (OS-only floor in the table). On macOS, PTY reads return about 1 KiB each and sys
  CPU grows roughly with the square of the number of flooding ptys (1 pty: 0.21 s sys
  for 30 MiB; 15 ptys: 29 s sys for 4.5 s wall) while total throughput stays at about
  100-130 MB/s, so the 15 kernel reader threads sit in `read()` at about 590 % CPU.
  On Linux it is plain CPU contention inside the guest (the floor drops to 12-14 ms when
  the cats run at nice 19, so it is not the host preempting the VM). Ruled out: every
  normal-scheduler NIF on the damage path reads the snapshot under a short mutex (never
  the core lock); core-lock calls are DirtyCpu or `try_lock`; rows are zero-copy; hidden
  panes emit no damage; GC is minor.
- (a) `8b8dafc3`, `353eec6a`, `f2139b98` (`dynide/native/dynide_kernel/src/bulk.rs`): a
  reader that reads ≥ 256 KiB within 100 ms is demoted (macOS `QOS_CLASS_UTILITY`,
  Linux nice 10) and promoted on the first read after a 100 ms idle gap or a window under
  32 KiB. Interactive output (echo, prompts, occasional redraws) never reaches the rate;
  a full-screen TUI redrawing at high frame rates (about 300 KiB per window) is demoted.
  Unit tests pin the demote/promote sequence, including the post-flood prompt. On Linux
  the nice stays at 10 without `CAP_SYS_NICE` (an unprivileged thread cannot lower its
  nice again); 10 rather than 19 because a stuck reader at 19 echoes at p95 33-126 ms
  under a 2x oversubscribed CPU (about 7 ms at 10). Cost: flood wall time 1.5-1.8x longer
  on macOS (11.5-12.9 s → 21-22 s for 1.5 GiB), about the same on Linux.
- After: macOS 11-19 ms (floor 61-92 ms), Linux 25-81 ms (floor 340-699 ms); typing p95
  7-12 ms on both. Still over 10 ms, which no process on these hosts gets under that
  load.
- (b) design.md row restated: "typing ≤ 20 ms p95; scheduler stall no worse than the
  host's OS-only floor, ≤ 10 ms where that floor allows" (two changes: stall clause
  restated, typing judged at p95 as M3 did). The floor is reproducible with
  `dynide/bench/gate/os_floor.sh`; a macOS run after the gate rounds gave flood max
  89-117 ms (idle 1.4-2.8 ms, flood wall 16.8-17.3 s), above the 61-92 ms of the gate
  rounds but the same order on a shared desktop; a Linux run of the committed script at
  `7722b36b` gave 360 / 16 / 655 ms (idle 1.6-2.0 ms, flood wall 5.0-5.7 s). The
  script's probe window (12 s) is shorter than the macOS flood (about 17 s), so it can
  only understate the macOS floor. A new design.md risk
  entry for PTY floods and the reader demotion policy.

### 3. Scrollback lost after about 18 handoffs (found in M6) (a)

- Found by Task 4a running `kill9.exs runs=24`: from about the 18th handoff every
  restored pane had lost its scrollback (`scrollback=0/5`); M5 ran 12.
- Root cause (Task 4d): ghostty's snapshot PAGE record stores no row capacity, so a
  restored screen page held exactly its own rows. The first new row after a restore
  opened a new page, the next snapshot froze it at one row, and each frozen page is
  charged a full pool item (409600 bytes at 100 cols) against `max_scrollback_bytes`.
  At 10 MB the budget runs out around trip 18; after that each trip prunes a page of
  real history. Graceful `kernel-restart` uses the same path.
- (a) `bb412b27`: vendored patch `0008-growable-restored-pages.patch` (indexed in
  `vendor/libghostty-vt.patches.md`): restored screen pages get the row capacity a new
  page of that width gets, when it still fits a pool item. Wire format unchanged; old
  blobs decode. Regression test `vt::tests::snapshot_round_trips_keep_scrollback` (30
  trips; failed at trip 18 before). The 30-handoff kill -9 check ran on macOS only;
  the Linux cell is 3 sessions of 12 handoffs, below the ~18-handoff point where the bug
  showed. `82aec93e`: `kill9.exs` now fails when any run has
  answered, scrollback or htop below N/N.

### 4. Promoted standby runs stale code (M5 ruling 28) (a)

- Measured (`dynide/bench/handoff/stale_standby.exs`): an edit saved after the standby
  booted was missing in the promoted VM in 3/3 runs, and the standby is only replaced on
  promotion or `kernel-restart`, so a crash silently reverted every edit since boot.
- (a) `55a1f61a`: when `HerdrReload.Server` starts (at promotion, via `start_deferred`)
  it loads every loaded module whose on-disk beam md5 differs from the loaded one,
  through the existing soft-purge loader, and never touches NIF modules (beams importing
  `erlang:load_nif/2`). About 3 ms on a normal start. After: 3/3, marker live 68-235 ms
  after the kill (macOS only; not measured on Linux). Regression test in `herdr_reload/test/server_test.exs`. M5's earlier
  attempt broke the tty harness `quit` check; that did not reproduce and its code was
  never committed, so its cause is unknown.
- Known cost: code loaded this way has no reload batch, so a failure in it is
  unattributed (no auto-rollback, no `herdr-live rollback`). The same beams are what a
  cold-booted VM would load anyway.

### 5. M1 StallTest flakes under load (a, test at fault)

- Reproduced 10/10 failures with 20 CPU burners, always on `mode_over <= ctrl_over + 3`
  (p999 passed every time).
- Root cause: the control (`:erlang.phash2/1` on a small term, about 50 ns) is not a
  fair control for `mode/2` (150-500 ns): a longer call is preempted more often. The
  snapshot-fallback lock was not over-represented, and the excess stayed with no cat
  flood at all.
- (a) `612c5f3b`: a duration-matched control (`phash2` over a 60-element list), mean ns
  of both printed, assertion `mode_over * 2 <= ctrl_over * 3 + 10`. Still fails on a
  deliberately blocking `mode` (2 ms busy-wait on 1 call in 50k: 3/3 quiet). 10/10 green
  under the same load. No kernel change.

### 6. kill -9: cold handoff and the 1085 ms outlier (no miss)

- 192 warm runs at load 6-17 (Task 4a) plus the 72 gate runs: no run over 300 ms; the
  1085 ms M5 outlier did not recur. The bench now keeps the broker log and prints
  per-run phases (`HERDR_BENCH_KEEP=1`, `1928245d`), so a recurrence names its step.
  Leading hypothesis: adoption failed on the standby and fell back to a fresh VM.
- Cold (no ready standby): 661-706 ms on both OSes at gate load; Task 4a's breakdown:
  86 ms exec to BEAM start, 655 ms Mix boot and app start, 46 ms preload, 3 ms adopt,
  31 ms restore. Starting standby/target VMs with `--no-compile` would save about
  170 ms; not taken (it would load whatever is on disk unchecked).

### 7. Linux bring-up (no product change)

M5's Linux paths (`exitwatch.rs` pidfd and `/proc` start time, `link.rs`, the broker)
compiled clippy-clean on first try. Three test-only Linux failures were fixed:
`aae102ab` (a zombie still answers `kill(pid, 0)`: wait for the reap; `pty::tests` 6/10 →
10/10 over ten loops), `0597545a` (root ignores mode 0500: skip that assertion when a
probe write succeeds), `e1e1262c` (dash dropped an `echo` sent together with ^C after a
2 MiB paste). `dc9267df`/`6d870c38`: the glass harness treated Linux's EIO on a pty
master with no slave fd open (while `bin/herdr-live` builds the broker) as the child's
exit.

## `just live-check`

- Linux, `6d870c38` (git archive export, podman): exit 0. credo and dialyzer clean;
  mix: herdr_scene 51, herdr_reload 81, herdr_term 89, herdr_server 201,
  herdr_integration 11 (+5 real_kernel); cargo: herdr_fdpass 11, herdr_kernel 85,
  herdr_term 52, herdr_broker 16; launcher smoke, handoff smoke, attached smoke and the
  tty harness: 64 PASS lines.
- macOS, `6d870c38` (CPU 70 % idle at start): exit 0. credo (1896 mods/funs) and
  dialyzer clean; the same mix and cargo counts as Linux; StallTest `mode_over_1ms=0
  control_over_1ms=0 mode_mean_ns=161 control_mean_ns=171`; `HANDOFF_SMOKE ok crash_ms=15
  graceful_ms=10`; 64 PASS lines.

## Rulings

Each: decision, then the cost if wrong.

1. Compose-helper NIF reverted after measurement; the Elixir fix stays the default. Cost: rebuild it from `15f728d4` if a 2-D placement NIF is ever needed.
2. Flood readers demote to utility QoS (macOS) / nice 10 (Linux); nice 10 not 19 because the Linux nice is sticky. Cost: Linux flood stall 25-81 ms instead of about 25-30.
3. Accept the flood wall-time increase (1.5-1.8x on macOS) for scheduler responsiveness. Cost: bulk output drains slower while the BEAM stays responsive.
4. Promotion-loaded code has no reload batch. Cost: a crash-causing edit is no longer escaped by accident through stale standby code; M7 should surface the synced module list.
5. Cold handoff left alone (meets < 1 s at gate load); `--no-compile` for standby VMs not taken. Cost: over 1 s on a heavily loaded host.
6. StallTest: the test, not the kernel, was at fault; the blocking `lock(&snapshot)` in `mode`'s stale fallback is kept (not measurable). Cost: a rare flake on a fully saturated host; a latent priority inversion if a reader is preempted inside that hold.
7. Benches ran on a shared desktop; numbers are recorded with load and CPU idle rather than waiting for an idle machine. Cost: tails (max values) are upper bounds.

## Known gaps

- A second real terminal window (another OS process) cannot attach until M16; the
  second-client row uses an in-VM client over the client protocol.
- Linux typing max during the flood is still 69-622 ms (p95 11-12 ms).
- A demoted Linux reader stays at nice 10 for the pane's life without `CAP_SYS_NICE`.
- The demoted reader still briefly holds the `encoders`/`snapshot` mutexes that some
  normal-scheduler NIFs block on; not measurable here.
- Kill -9 during a Mix compile can leave a mixed (valid) beam set on disk that a promoted
  standby then loads.
- No Zig unit test pins patch 0008's relaxed capacity check; the Rust round-trip test
  is the regression check.
- Linux is aarch64 in a VM on the same Mac; x86_64 and bare-metal Linux were not run.
- Deferred minors from task reviews are listed in the SDD ledger; none blocks the gate.

## Re-running the gate after the M7 prune

M7 removed the Rust `src/` tree, so the `herdrref` suite and `glass.py herdr` no longer
build the root crate. `dynide/bench/gate/herdr_ref.sh` builds the `herdr-reference` tag
(the last commit with `src/`) from `git archive` into
`${XDG_CACHE_HOME:-$HOME/.cache}/herdr-live/herdr-reference/<short sha>`, and
`gate_round.sh <tag> herdrref` runs `render_scale_profile` in that tree. Set `HERDR_BIN`
to use another herdr binary for `glass.py herdr`; the `herdrref` suite is then skipped
unless the tree is already extracted. The numbers above are unchanged.
