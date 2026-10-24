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
| M0 skeleton | in progress | live/m0 | agent | | started 2026-10-23 |
| M1 kernel vt+pty | not started | | | | wave 1 |
| M2 term kernel tty+blit | not started | | | | wave 1 |
| M3 server core + term client | not started | | | | wave 1 |
| M4 reload + rollback | not started | | | | wave 1 (prep), wave 2 |
| M5 kernel restart | not started | | | | wave 2 |
| M6 gate | not started | | | | human decision |
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
