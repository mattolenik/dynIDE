# 0001: Slice-1 gate

## Status

Proposed, 2026-10-24, by the M6 owner agent. The decision belongs to the human.

## Context

design.md "Slices and go/no-go" asks slice 1 to prove the hard cases before the
breadth work (M7-M18, roughly 100k lines rewritten) is paid for: the client-protocol
hop on the keystroke path, composition cost in Elixir, the kernel under a 15-pane cat
flood, live reload with rollback, and kernel restart under live children. M6 ran the
full table three times on macOS (M1 Max) and three times on Linux (aarch64 podman VM on
the same Mac), with a herdr reference measured the same way where the target is
relative. Evidence: [results/m6-gate.md](../results/m6-gate.md).

| metric | macOS p95 | Linux p95 | target | verdict |
|---|---|---|---|---|
| keystroke → glass vs herdr (real pty) | +174-269 µs | +201-401 µs | ≤ herdr + 1 ms | met |
| frame, 15 full panes, 120x40 | 162-175 µs (herdr 652-689) | 177-183 µs (herdr 726-755) | (b) ≤ herdr | met |
| frame ratio 1 vs 15 | 2.4-2.8x (herdr 1.13-1.18x) | 2.3-3.1x (herdr 1.12-1.14x) | was ≤ 2x herdr's | missed, restated |
| cat flood: typing | 7.2-7.6 ms | 11.4-12.0 ms | ≤ 20 ms | met |
| cat flood: scheduler stall | 11-19 ms (OS-only floor 61-92) | 25-81 ms (floor 340-699) | was ≤ 10 ms | missed, restated |
| edit Render / View → visible | 288-296 / 186-196 ms | 282-296 / 183-191 ms | < 500 ms | met |
| App.Ui field under load | 297-317 ms, fan-out 3 | 294-300 ms, fan-out 3 | < 1 s | met |
| App.Session / Scene field | 266-281 / 465-479 ms, fan-out 2 / 3+1 | 276-280 / 472-502 ms | record | recorded |
| View.compute infinite loop | 62-64 ms | 68-72 ms | ≤ 150 ms | met |
| closure in state, second reload | rejected 0.3-0.5 ms | 0.4-0.5 ms | rejected | met |
| rollback with pane in window | 8-14 ms, adopted | 9-13 ms | reconciled | met |
| reload during 15-pane cat | 429-463 ms | 907-1423 ms | measure | recorded |
| kill -9, 15 shells, ready standby | 42 ms (max 48) | 63 ms (max 63) | < 1 s | met |
| kill -9, no standby (cold) | 671-676 ms | 661-706 ms | report | under 1 s |
| second client, other size | 321-368 µs, both correct | 596-653 µs | correct, visible | met (in-VM client) |

The gate also found and fixed two defects that would have broken the "never lose
terminals, scrollback, or layout" promise: scrollback lost after about 18 handoffs
(vendored ghostty patch 0008) and a promoted standby silently running the code it
booted with (M5 ruling 28). The M1 StallTest flake was the test's fault.

## Decision

Recommendation: **go with changes.** The architecture holds. Every reload, rollback
and kernel-restart target is met on both OSes with wide margins, the local
client-protocol hop costs 0.2-0.4 ms over herdr, and a 15-pane full repaint costs
about a quarter of herdr's frame pipeline (herdr's figure also builds pane surfaces;
herdr-live's starts from kernel-packed rows and excludes the scene compute). Two targets are missed as written, and in both the miss is not
the architecture's:

(b) changes written into design.md (each marked "M6 gate change"):

1. Frame-cost row: judge 15-pane full repaints against herdr's absolute cost at the
   same geometry and record the ratio. The ratio compared a borderless 1-pane frame
   (one copy per row) with about 1045 assembled segments, so it measured Elixir
   per-term overhead rather than the cost that bounds a frame. The design's
   compose-helper NIF was prototyped and gave nothing at 15 panes; the risk entry now
   says so and names the next lever (a NIF that places whole pane rectangles).
2. Cat-flood row: typing ≤ 20 ms p95 (unchanged), and the scheduler stall no worse than
   the host's OS-only floor (a BEAM probe next to 15 pty floods with no herdr code),
   ≤ 10 ms where that floor allows. On both hosts the floor is 3-30x the 10 ms target.
3. New risk entry: PTY floods starve schedulers through the OS; the kernel demotes
   flooding readers (macOS utility QoS, Linux nice 10, sticky without `CAP_SYS_NICE`).

M7 must do first, before the dogfooding week:

1. Surface reload state that M6 left invisible: the modules a promoted standby
   synced from disk (they have no batch, so no rollback), and handoff phases from the
   broker log.
2. Run the human GUI-terminal checks still owed from M2 and M3 (procedures in their
   results), now with the QoS demotion in place, and watch a fast full-screen TUI,
   which the demotion treats as bulk output.
3. Re-run the kill -9 bench with `runs=30` after any change to the snapshot path or a
   libghostty-vt bump (patch 0008 must be kept or dropped deliberately).

## Consequences

- Easier: M7+ can build on the reload and handoff machinery as is; the gate benches
  (`live/bench/gate_round.sh`, `live/scripts/linux_check.sh`, `bench/gate/glass.py`)
  re-run the whole table on either OS.
- Harder: two targets are now relative to a measured reference (herdr, OS floor), so
  they need that reference re-measured on the same host every time.
- Costs if wrong: if per-segment Elixir work grows with overlays and graphics, frames
  get slower than herdr's and the pane-rectangle NIF is needed in M9/M10. If the
  stall restatement hides a herdr-specific problem, it would show as long schedules in
  herdr processes that the OS-only floor does not have; the Linux flood typing max
  (69-622 ms, p95 12 ms) is the number to watch.
- Revisit when: a bare-metal Linux or x86_64 run disagrees with these numbers, or the
  M7 dogfooding log shows input stalls during builds.

## Alternatives considered

- **Go as is (no design changes).** Rejected: two rows would stay red with no plan,
  and the gate would not have said why.
- **No-go.** Rejected: no miss traces to the BEAM/NIF split. The stall reproduces with
  no herdr code, and composition is cheaper than herdr's in absolute terms.
- **Switch Render to the compose-helper NIF.** Rejected: measured no gain at 15 panes,
  and it moves code out of the hot-reloadable brain.
- **Static low priority for all PTY readers.** Rejected: it would also demote
  interactive panes; the adaptive demotion keeps echo at default priority.
