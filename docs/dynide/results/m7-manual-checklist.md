# M7 manual checklist (human, GUI terminal)

One checklist for the manual checks owed to the human before and during the M7
dogfooding week. It merges the GUI-terminal procedures left pending in
[m2.md](m2.md) and [m3.md](m3.md), ADR 0001 item 2 ([adr/0001-slice-1-gate.md](../adr/0001-slice-1-gate.md)),
the reload loop by a human, and a crash handoff. Related guide: [../editing-live.md](../editing-live.md).

Run in one GUI terminal (Ghostty, iTerm2 or Terminal.app; one is enough to accept, more
is better). Record at the top: terminal and version, OS, date, commit (`git rev-parse --short HEAD`).

```
terminal:            version:            OS:            commit:            date:
```

Conventions: `[ ]` pass / fail boxes are `[ ] pass  [ ] fail`. "Window A" is the GUI
terminal under test, "window B" a second terminal window or tab of any kind. Paths are
relative to the repo root of the `live/m7` worktree (`/Users/matt/herdr-project/herdr-live-worktrees/m7`
or the integrated `herdr-live` checkout). Note any visual artefact (debris, wrong
colours, cursor shape or position) in the notes line of the step.

## A. Terminal client (from m2.md): `just live-demo`

The throwaway tty/blit demo. It compiles quietly and logs to
`~/.local/state/herdr-live/live-demo.log`.

| # | Step (window A unless noted) | Expected | Result |
|---|---|---|---|
| A1 | `just live-demo` | Alt screen. Header `herdr-live demo <cols>x<rows> pid <pid>`, a box, a counter ticking every 250 ms, a colour gradient row, a `漢字` row. Typing changes `last input:`. | [ ] pass  [ ] fail |
| A2 | Press Ctrl-Z | Shell prompt back on the normal screen; cooked shell works (`ls` echoes and runs). | [ ] pass  [ ] fail |
| A3 | Run `fg` | Demo screen comes back fully repainted; counter keeps ticking. | [ ] pass  [ ] fail |
| A4 | Resize the window | Header shows the new size; screen repaints without debris. (Debris means the resize repaint needs `ESC[2J`.) | [ ] pass  [ ] fail |
| A5 | Window B: `kill -9 <pid>` (the pid in the header) | Window A: original screen back, the prompt, usable terminal: typing echoes and `stty -a` shows `icanon echo`. Cursor shape and position are right. | [ ] pass  [ ] fail |
| A6 | `just live-demo` again, press Ctrl-Z, then `kill %1` (bash/zsh may also need `fg`) | Clean restore and the prompt. | [ ] pass  [ ] fail |
| A7 | `just live-demo` again, press `q` | Clean exit, status 0 (`echo $?`). | [ ] pass  [ ] fail |

Notes (terminal, version, artefacts, cursor after restore):

## B. herdr-live in a real terminal (from m3.md, Task 16 "not covered by a script")

`just live-run` (same as `dynide/bin/dynide`). The prefix is ctrl-b. Panes run your shell.
Prepare a big file once: `seq 1 3000000 > /tmp/herdr-big.txt` (about 22 MB).

| # | Step | Expected | Result |
|---|---|---|---|
| B1 | `just live-run` in window A | Alt screen, one pane with a shell, status line at the bottom. | [ ] pass  [ ] fail |
| B2 | Split: `ctrl-b v`, then `ctrl-b -`; repeat until there are 15 panes (clicking a pane focuses it, mouse first) | Every split draws borders without tearing; the splits stop (refused) when too small, not crash. | [ ] pass  [ ] fail |
| B3 | In one pane: `cat /tmp/herdr-big.txt`; at once click another pane and type `echo typed-ok` + enter | The typed text echoes immediately while `cat` is running; no tearing, no flicker in other panes. | [ ] pass  [ ] fail |
| B4 | In a pane: `htop` | htop draws correctly (bars, colours, header), keys work, `q` leaves it. | [ ] pass  [ ] fail |
| B5 | Resize window A | Panes reflow, no debris, shells see the new size (`stty size`). | [ ] pass  [ ] fail |
| B6 | Second terminal client at another size (m3 item 2): needs the M16 transport, not available. Substitute: resize window A narrow (about 80x24), then wide, with `cat` running | Layout adapts both ways; content intact. | [ ] pass  [ ] fail  [ ] skipped |
| B7 | `ctrl-b q` | herdr-live exits with status 0 (`echo $?`); tty is cooked and the prompt is back; no stray escape sequences. (Detach and quit are the same today.) | [ ] pass  [ ] fail |

Notes:

## C. Reader demotion under bulk output (ADR 0001 item 2)

Since M6 the kernel demotes a PTY reader that reads at least 256 KiB within 100 ms
(macOS utility QoS, Linux nice 10) and promotes it after a 100 ms idle gap. The gate
asked a human to look for visible lag, and to watch a fast full-screen TUI, which the
demotion treats as bulk output.

Start `just live-run`. Make at least 4 panes. In window A:

| # | Step | Expected | Result |
|---|---|---|---|
| C1 | In pane 1 run `htop`. In pane 2 run `yes \| head -n 2000000`. Type in pane 3 meanwhile (`echo c1-ok`, edit a long line, hold a key for repeat) | htop keeps refreshing at its usual rate (note any stutter or frozen frames); the `yes` pane scrolls and ends; typing in pane 3 echoes without noticeable delay. Note visible lag in ms-ish terms ("none", "small", "bad") here: ______ | [ ] pass  [ ] fail |
| C2 | In pane 2 run a fast build log: `cd dynide/native/dynide_kernel && cargo build -vv` (touch a source first so it rebuilds, e.g. `touch src/lib.rs`), or `yes \| head -n 2000000` again. Type in pane 3 and watch htop in pane 1 | Same as C1: typing responsive, htop alive. Note lag: ______ | [ ] pass  [ ] fail |
| C3 | After the flood ends, type at a prompt in pane 2 | Echo is immediate again (the reader was promoted back); no residual lag. | [ ] pass  [ ] fail |
| C4 | Fast full-screen TUI in a pane: `htop -d 1` (fastest refresh) or `watch -n 0.1 'ls -l /'`; if you have a TUI that redraws at high frame rates (a pager with a fast scroll, `vtop`, a game), use it. Watch it for 30 s while typing in another pane | The TUI stays smooth enough to use (a demoted reader may slow a very fast TUI; record how it looks, "smooth" / "slower than in a plain terminal" / "visibly stuttering"): ______ Typing elsewhere is unaffected. | [ ] pass  [ ] fail |
| C5 | Same C1 under the demotion with window A resized during the flood | No crash, no debris once the flood ends. | [ ] pass  [ ] fail |

Notes (record numbers for the revisit rule: "if the dogfooding log shows input stalls
during builds"):

## D. Reload loop by a human

With herdr-live running (B1). Use a second window B or a pane in herdr-live for the edits.
The loop is explained in [../editing-live.md](../editing-live.md); do the edits in
`dynide/apps/dynide_server/lib/dynide_server/view.ex` (or any chrome text the status line
shows).

| # | Step | Expected | Result |
|---|---|---|---|
| D1 | Edit `View`: change a visible chrome text (for example a status label), save | Within about half a second the new text is on screen without losing panes, scrollback or layout; status line shows `r<N> <k>m` and a notice `reloaded <k> modules`. | [ ] pass  [ ] fail |
| D2 | Break it: make `View.compute` raise (for example `raise "boom"` as its first line), save | Status line shows `r<N> rolled back: ...` and the notice `rolled back batch <N> ...`; the previous text is still on screen; panes and shells untouched; the multiplexer keeps working. | [ ] pass  [ ] fail |
| D3 | Hang it: put `Process.sleep(:infinity)` in `View.compute`, save, then resize window A | After the 50 ms budget it rolls back; the resize is not lost (the scene is at the new size). | [ ] pass  [ ] fail |
| D4 | Compile error: remove a closing `end`, save | Status line shows `r! compile` and an error notice with file:line; the running code is unchanged. Fix and save: loads normally. | [ ] pass  [ ] fail |
| D5 | Re-save the rolled-back source unchanged (or `touch` it) | Nothing happens (by design). Then revert the edit and save: it reloads. | [ ] pass  [ ] fail |
| D6 | `dynide/bin/dynide rollback` after a good edit | Prints `ok <id>`; the edit is undone on screen. `herdr-live rollback` again with nothing to undo prints `ok none`. | [ ] pass  [ ] fail |
| D7 | `dynide/bin/dynide test-on-save on`, save an edit that breaks `view_test.exs`, then fix and re-save | Status shows `tests...` then `tests <n> failed`, nothing loaded; after the fix and a re-save of the lib file, `tests ok` and the change loads. Then `test-on-save off`. | [ ] pass  [ ] fail |
| D8 | Revert all edits (`git checkout -- dynide/apps`) | Reloads to the original; `git status` clean. | [ ] pass  [ ] fail |

Notes (latency you felt, anything that looked wrong):

## E. Kernel restart

| # | Step | Expected | Result |
|---|---|---|---|
| E1 | With `cat /tmp/herdr-big.txt` and a typing pane running, in window B run `dynide/bin/dynide kernel-restart` | Prints a success line; the screen repaints briefly; every pane, its scrollback and its running program survive; keys typed meanwhile are not lost. Status line shows `handoff graceful g<gen>` for about 30 s. | [ ] pass  [ ] fail |
| E2 | `dynide/bin/dynide status` | `primary_gen` advanced, `standby_ready=1` after a moment, `phase=idle`. | [ ] pass  [ ] fail |

## F. Crash handoff (`kill -9` of the primary VM)

| # | Step | Expected | Result |
|---|---|---|---|
| F1 | In window A have several panes with distinct content (a shell with history, `htop`, a `seq 1 3000` output). In window B: `dynide/bin/dynide status` and read `primary_pid` and `standby_ready` (wait for `standby_ready=1`) | `primary_pid=<pid>` printed. | [ ] pass  [ ] fail |
| F2 | Window B: `kill -9 <primary_pid>` (that exact pid only) | Window A repaints within a second; all panes are still there with their processes; scrollback present (as of the last snapshot, at most about 1 s old); htop running; typing works. Status line shows `handoff crash g<gen>`. | [ ] pass  [ ] fail |
| F3 | `dynide/bin/dynide status` | New `primary_gen` and `primary_pid`, `last_handoff_kind=crash`. | [ ] pass  [ ] fail |
| F4 | `just live-log-summary` | Shows the crash handoff and no `session_lost`. | [ ] pass  [ ] fail |
| F5 | Make a reload edit (D1 style) right after the crash handoff | Loads normally in the new primary. If you edited something before the crash and after the standby booted, the status line shows `synced <k>m, no rollback`. | [ ] pass  [ ] fail |
| F6 | `ctrl-b q` | Clean exit, status 0, tty cooked. | [ ] pass  [ ] fail |
| F7 | Last, destructive (ends the session and its panes). m3 asked for "kill -9 the VM from another window; the tty must come back cooked": with the broker that kill is the crash handoff of F2, not a tty restore. To test the worst case, run `just live-run` again, then in window B read `broker_pid` from `dynide/bin/dynide status` and run `kill -9 <broker_pid>` (that pid only) | Truthful expectation: a SIGKILLed broker cannot run its own restore (`native/herdr_broker/src/tty.rs`). The VMs lose their broker link and halt (the private `halt/1` in `handoff/link.ex`), so the session and its panes end (the broker is the only holder of the pane fds). Since M17 the launcher runs the broker under `scripts/tty_guard.sh`, which restores the saved termios and writes the restore sequence: the tty comes back cooked on the main screen, mouse reporting off, and `reset` is not needed. The launcher exits 137 and the log has `herdr-event broker_killed` (counted as `operator_kills`, not a session loss). Record what you actually see; a raw tty or a needed `reset` is a failure. | [ ] as described  [ ] other: ______ |

Notes:

## Sign-off

- [ ] Every step above passed, or each failure is recorded in the notes with the step id.
- [ ] Attach the log summary: `just live-log-summary > /tmp/herdr-m7-summary.txt`.
- Verdict: ______  Signed: ______  Date: ______
