# 0002: Scrollback persistence

## Status

Accepted, 2026-10-24, M8 owner (coordinator ruling on the human's behalf; not a human
decision point).

## Context

M8 restores a session after herdr-live stops (clean stop, reboot, or a crash with no
standby): layout, cwds and metadata come back from `session.<name>.etf`, and the shells
are new processes. The live handoff (M5) already keeps everything across a kernel
restart, using ghostty's snapshot format (M5 ruling 4). What a restored pane shows of its
old output is a separate choice, because it is paid on disk every time a pane changes.

Measured with `dynide/bench/persist/scrollback_cost.exs` (real kernel, 80x24, 10 MB
`max_scrollback`, written through `Persist.Disk` as compressed ETF and synced). Two
workloads: `seq` lines and `ls -la --color`-like lines filling 79 columns with SGR. `full`
is all history ghostty holds under 10 MB: 14 044 rows at 80 columns for both workloads
(30 000 lines fed); `tail` is clamped by the kernel to 10 000 rows. Byte counts are
deterministic. Timings are two runs on a shared M1 Max at load average 35-37 (1 min),
55-60 (5 min), so they are upper bounds.

| option | work | rows | on disk | raw | capture µs | write µs | restore µs |
|---|---|---|---|---|---|---|---|
| none | any | 0 | 0 | 0 | 0 | 0 | 0 |
| tail | seq | 1 000 | 1 985 | 4 946 | 176-200 | 5 933-17 440 | 261-276 |
| tail | seq | 10 000 | 22 189 | 58 970 | 1 221-1 239 | 3 040-3 414 | 1 271-1 274 |
| tail | seq | full (10 000 cap) | 20 848 | 69 998 | 1 235-1 379 | 2 693-3 695 | 1 391-1 555 |
| snapshot | seq | 1 000 | 2 887 | 7 176 | 87-105 | 1 511-1 573 | 277-383 |
| snapshot | seq | 10 000 | 23 277 | 70 710 | 390-435 | 3 863-16 918 | 1 063-1 155 |
| snapshot | seq | full 14 044 | 31 890 | 114 214 | 406-501 | 4 360-4 365 | 1 450-1 514 |
| tail | sgr | 1 000 | 10 498 | 88 012 | 261-272 | 1 738-2 837 | 353-383 |
| tail | sgr | 10 000 | 96 239 | 880 012 | 2 368-2 373 | 8 506-9 534 | 2 005-2 081 |
| tail | sgr | full (10 000 cap) | 95 641 | 880 012 | 2 302-2 444 | 8 785-8 842 | 2 125-2 231 |
| snapshot | sgr | 1 000 | 14 645 | 165 861 | 126-152 | 2 920-3 658 | 356-392 |
| snapshot | sgr | 10 000 | 131 779 | 1 615 641 | 985-1 110 | 20 657-21 522 | 2 192-2 211 |
| snapshot | sgr | full 14 044 | 183 678 | 2 263 225 | 1 561-1 780 | 28 396-28 961 | 2 997-3 041 |

Write amplification, worst case (15 panes, every pane changes every minute, 60 writes per
pane per hour, on-disk bytes): tail 1 000 rows 1.8 MB/h (seq) to 9.4 MB/h (sgr), about
43-227 MB/day; tail 10 000 rows 20-87 MB/h (0.5-2.1 GB/day); full snapshot 29-165 MB/h
(0.7-4.0 GB/day). Write time is dominated by `fsync`, not by size.

## Decision

Each pane's last N rows (default `scrollback_rows: 1000`) are persisted as unwrapped VT
text from `vt_tail_ansi` (SGR kept, soft wraps joined, trailing blank rows dropped), one
file per pane under `session.<name>.scrollback/`. The Writer writes them every 60 s
(`scrollback_ms`) for panes whose content generation changed, and for every pane at clean
stop. On restore the text is fed into the new pane's vt before the shell starts, so the
prompt appears below the old output. The alternate screen is not captured (the previous
file is kept while a full-screen program runs). `scrollback_rows: 0` persists none.

The numbers support the default: 2-10.5 KB per pane on disk, well under the 500 KB
budget, and under 0.4 ms to capture or replay. The config default stays 1000.

## Consequences

- A restored pane shows readable recent context with colours, re-wrapped to the new
  width, and inherits no modes, cursor state or alt screen from the dead process.
- Output from the last minute before a crash can be missing (clean stop writes all).
- Rows above N are lost on restore (live handoff still keeps the full history).
- The file format is ours (plain VT in a versioned envelope), so libghostty-vt bumps do
  not invalidate it.
- At 1 000 rows the worst case is about 230 MB/day of writes for 15 busy panes; real
  panes are idle most of the time, and only changed panes are written.

Revisit if: users ask for more history than 1 000 rows by default (10 000 costs about 10x
on disk and in writes, still under 100 KB/pane); write volume shows up in SSD wear or
battery reports; restore replay at the chosen N exceeds about 50 ms per pane; ghostty's
snapshot format gains a stability guarantee; or `tail_ansi`'s 10 000-row cap is reached
by the configured N.

## Alternatives considered

- **None.** Zero cost, but a restored pane is blank and the user loses all context of
  what each pane was doing; kept as `scrollback_rows: 0`.
- **Full ghostty snapshot.** Up to 184 KB per pane on disk (2.3 MB raw) and 17x the
  writes of the chosen default for the SGR workload. Its format is not stable across
  libghostty-vt bumps (M5 ruling 4): a vendor update would blank every restored pane.
  It also carries modes, cursor, the alt screen and parser state of a process that no
  longer exists into a new shell.
- **Full history as ANSI.** Kept text with the cap removed would write the whole 10 MB
  history (about 14 000 rows here, more at narrower widths) each minute for every
  changed pane: about 10-15x the default's write amplification for context users rarely
  scroll back to after a restart.
