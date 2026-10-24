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
| M1 kernel vt+pty | in progress | live/m1 | agent | | wave 1; two-phase: packed cell spec first (SPEC_PUBLISHED), then rest |
| M2 term kernel tty+blit | in progress | live/m2 | agent | | wave 1; waits on packed cell spec for decode |
| M3 server core + term client | in progress | live/m3 | agent | | wave 1; against Kernel.Fake; owns scene contract |
| M4 reload + rollback | in progress (phase 1) | live/m4 | agent | | wave 1 prep: Reload.* against toy modules; phase 2 after M3 |
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
- 2026-10-23: M0 DONE_WITH_CONCERNS at 179cd23e; coordinator re-ran `just live-check` on merged tree: exit 0. Fast-forwarded into herdr-live. Concerns carried: Linux CI never executed (no push); the M0 owner's Linux subagent added a 6 GiB swapfile at /var/tmp/swapf inside the podman VM and left a `herdr-linux-check` image.
- 2026-10-23: wave 1 dispatched: M1, M2, M3, M4-prep owners on live/m1..m4 from 179cd23e.
- 2026-10-23: M1 SPEC_PUBLISHED at 03846db6 (HerdrScene.Cell: 32-byte LE records, per-row trailer for long clusters, 15 golden vectors from an independent Python encoder, docs/herdr-live/packed-cells.md). Merged into herdr-live; herdr_scene 21 tests pass. M1 resumed for phase 2; M2 and M3 told to rebase.

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
