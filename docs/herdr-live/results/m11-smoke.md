# M11 live smoke: real agents through idle / working / blocked

Exit criterion (milestones.md M11): a live smoke with at least two real agents through
idle, working and blocked, recorded with CLI versions and observed signals, plus
`agent read` / `agent explain` from inside a pane. Script:
[live/scripts/agent_live_smoke.py](../../../live/scripts/agent_live_smoke.py) (not in
`live-check`: it needs authenticated agent CLIs and spends model tokens). Run on branch
`live/m11` at `acfb8ba2` plus the script, macOS 26.5 (Darwin 25.5), 2026-10-25, from a
reference-herdr pane (its `HERDR_*` env and the calling Claude Code session's `CLAUDE*`
env stripped from the launched instance; never inside herdr-live).

## Result

Three of three agents pass all three states, in two consecutive full runs (both exit 0).

| agent | version | launch line | idle | working | blocked | deny -> idle | idle signal | working signal | blocked signal | hook_source |
|---|---|---|---|---|---|---|---|---|---|---|
| claude | 2.1.310 (Claude Code) | `claude --permission-mode default` | 3.5 / 3.6 s | 0.3 / 0.4 s | 3.2 / 3.4 s | 0.4 / 0.6 s | `live_prompt_box` (prompt_box_body, `❯ `) | `osc_title_working` (osc_title, `◐ Claude Code`) | `bash_permission_prompt` (whole_recent, "Do you want to proceed?") | none |
| codex | codex-cli 0.164.0 | `codex -s read-only -a on-request -c approvals_reviewer="user"` | 3.4 / 3.3 s | 0.4 / 0.4 s | 4.1 / 7.4 s | 0.4 / 0.4 s | `osc_title_idle` (osc_title, `Explain terminal multiplexers \| m11`) | `osc_title_working` (osc_title, braille spinner `⠼ m11`) | `osc_title_blocked` (osc_title, `[ . ] Action Required \| ...`) | none |
| opencode | opencode v2.0.22 | `OPENCODE_CONFIG_CONTENT='{"permission":{"bash":"ask"}}' opencode --standalone` | 3.5 / 3.4 s | 0.2 / 0.2 s | 2.6 / 3.0 s | 0.4 / 0.4 s | screen fallback `default_known_agent_idle_fallback` (before the first hook report), then hook | hook | hook | `herdr:opencode` from the first prompt on |

Times are run1 / run2. `idle` is from `pane run` of the CLI (it includes the 3 s startup
grace); `working` and `blocked` from `agent prompt`; deny is `agent send-keys esc` on the
approval. Every deny left no marker file (the command did not run), every agent exited on
ctrl+c twice and dropped out of `agent list`.

From inside a pane (the first pane's shell, `"$HERDR_LIVE_BIN" agent read <id> --lines 20`
and `"$HERDR_LIVE_BIN" agent explain <id>`): both exit 0 for all three agents in both runs.
Run2 text explain output:

```
agent: claude | state: idle | manifest: bundled 2026.10.11.1 | rule: live_prompt_box (region=prompt_box_body priority=950) | evidence: "❯ \n"
agent: codex | state: idle | manifest: bundled 2026.10.11.1 | rule: osc_title_idle (region=osc_title priority=100) | evidence: "Explain terminal multiplexers | m11"
agent: opencode | state: idle | manifest: none unknown | rule: none
```

## Observations

- **opencode is hook-driven.** The user's herdr plugin
  (`~/.config/opencode/plugins/herdr-agent-state.js`) reports through `HERDR_SOCKET_PATH`
  (herdr-live's alias), so `hook_source` is `herdr:opencode` and `agent explain` then shows
  `manifest: none unknown | rule: none` (the hook is the authority; explain does not name the
  hook). The screen manifest alone was checked offline with `agent explain --file` on the
  captured run2 screens: idle -> `default_known_agent_idle_fallback`, working ->
  `progress_bar_working` (whole_recent), blocked -> `permission_required` (whole_recent),
  so screen detection would also have reached all three states.
- **codex hooks did not report.** `~/.codex/hooks.json` installs herdr's codex hooks, but no
  `hook_source` appeared; codex 0.164 runs hooks only after persisted hook trust (the status
  line shows `⚠ 1`). Not bypassed (`--dangerously-bypass-hook-trust`); codex states came
  from its OSC title.
- **Launch flags needed to get an approval prompt.** claude: the user's settings default to
  auto mode, which does not ask (and showed a "Teach auto mode about your environment?"
  dialog after the first turn, which detection read as blocked via `live_blocked_form`).
  codex 0.164 has no `-a untrusted`; the config's `approvals_reviewer = "auto_review"` would
  answer approvals itself, so the user is put back as reviewer and the sandbox is read-only.
  opencode: its default bash permission is allow (a trial run executed the `touch` without
  asking); v2's TUI talks to a background service, which ignores the TUI's env, so
  `--standalone` (a private server, also keeping the smoke out of the user's own service) makes
  the env config apply. No startup trust dialog appeared for any CLI.
- **One unreproduced early idle (codex).** In a development run (not the two final ones)
  codex read `idle` via `osc_title_idle` 0.4 s after `working`, with no transcript on screen
  yet; that run captured no screen at the state, and the next three codex runs went
  working -> idle after 25-27 s as expected. If it recurs, the evidence to capture is the
  title sequence around the prompt.

## Raw output

### run1

```
PASS: herdr: alt screen, first frame with TERMINAL status and the pane's prompt
PASS: smoke: claude idle via rule live_prompt_box region prompt_box_body in 3.5s (screen says idle, hook_source None)
PASS: smoke: claude working via rule osc_title_working region osc_title in 0.3s (screen says working, hook_source None)
PASS: smoke: claude idle_after_work via rule live_prompt_box region prompt_box_body in 12.2s (screen says idle, hook_source None)
PASS: smoke: claude agent read and agent explain from inside pane p1 succeed
PASS: smoke: claude blocked via rule bash_permission_prompt region whole_recent in 3.2s (screen says blocked, hook_source None)
PASS: smoke: claude idle_after_deny via rule live_prompt_box region prompt_box_body in 0.4s (screen says idle, hook_source None)
PASS: smoke: claude denied command did not run (no /Users/matt/herdr-project/herdr-live-worktrees/m11/.superpowers/sdd/m11/tmp/smoke/run1/herdr-m11-claude)
PASS: smoke: claude exited, agent list no longer has p2
PASS: smoke: codex idle via rule osc_title_idle region osc_title in 3.4s (screen says idle, hook_source None)
PASS: smoke: codex working via rule osc_title_working region osc_title in 0.4s (screen says working, hook_source None)
PASS: smoke: codex idle_after_work via rule osc_title_idle region osc_title in 27.0s (screen says idle, hook_source None)
PASS: smoke: codex agent read and agent explain from inside pane p1 succeed
PASS: smoke: codex blocked via rule osc_title_blocked region osc_title in 4.1s (screen says blocked, hook_source None)
PASS: smoke: codex idle_after_deny via rule osc_title_idle region osc_title in 0.4s (screen says idle, hook_source None)
PASS: smoke: codex denied command did not run (no /Users/matt/herdr-project/herdr-live-worktrees/m11/.superpowers/sdd/m11/tmp/smoke/run1/herdr-m11-codex)
PASS: smoke: codex exited, agent list no longer has p3
PASS: smoke: opencode idle via rule None region None in 3.5s (screen says idle, hook_source None)
PASS: smoke: opencode working via rule None region None in 0.2s (screen says working, hook_source herdr:opencode)
PASS: smoke: opencode idle_after_work via rule None region None in 30.9s (screen says idle, hook_source herdr:opencode)
PASS: smoke: opencode agent read and agent explain from inside pane p1 succeed
PASS: smoke: opencode blocked via rule None region None in 2.6s (screen says blocked, hook_source herdr:opencode)
PASS: smoke: opencode idle_after_deny via rule None region None in 0.4s (screen says idle, hook_source herdr:opencode)
PASS: smoke: opencode denied command did not run (no /Users/matt/herdr-project/herdr-live-worktrees/m11/.superpowers/sdd/m11/tmp/smoke/run1/herdr-m11-opencode)
PASS: smoke: opencode exited, agent list no longer has p4
PASS: quit: prefix q (detach) exits 0 (got 0)
PASS: quit: kitty flags popped, then the alt screen left
PASS: quit: tty settings unchanged
PASS: quit: log has herdr-live stopped

agent      version                    idle  working  blocked  deny->idle  hook_source  pass
claude     2.1.310 (Claude Code)      3.5   0.3      3.2      0.4         None         True
codex      codex-cli 0.164.0          3.4   0.4      4.1      0.4         None         True
opencode   opencode v2.0.22           3.5   0.2      2.6      0.4         herdr:opencode True
PASS: smoke: 3 agents reached idle, working and blocked (['claude', 'codex', 'opencode'])
results: /Users/matt/herdr-project/herdr-live-worktrees/m11/.superpowers/sdd/m11/tmp/smoke/run1/results.json
```

### run2

```
PASS: herdr: alt screen, first frame with TERMINAL status and the pane's prompt
PASS: smoke: claude idle via rule live_prompt_box region prompt_box_body in 3.6s (screen says idle, hook_source None)
PASS: smoke: claude working via rule osc_title_working region osc_title in 0.4s (screen says working, hook_source None)
PASS: smoke: claude idle_after_work via rule live_prompt_box region prompt_box_body in 9.7s (screen says idle, hook_source None)
PASS: smoke: claude agent read and agent explain from inside pane p1 succeed
PASS: smoke: claude blocked via rule bash_permission_prompt region whole_recent in 3.4s (screen says blocked, hook_source None)
PASS: smoke: claude idle_after_deny via rule live_prompt_box region prompt_box_body in 0.6s (screen says idle, hook_source None)
PASS: smoke: claude denied command did not run (no /Users/matt/herdr-project/herdr-live-worktrees/m11/.superpowers/sdd/m11/tmp/smoke/run2/herdr-m11-claude)
PASS: smoke: claude exited, agent list no longer has p2
PASS: smoke: codex idle via rule osc_title_idle region osc_title in 3.3s (screen says idle, hook_source None)
PASS: smoke: codex working via rule osc_title_working region osc_title in 0.4s (screen says working, hook_source None)
PASS: smoke: codex idle_after_work via rule osc_title_idle region osc_title in 26.9s (screen says idle, hook_source None)
PASS: smoke: codex agent read and agent explain from inside pane p1 succeed
PASS: smoke: codex blocked via rule osc_title_blocked region osc_title in 7.4s (screen says blocked, hook_source None)
PASS: smoke: codex idle_after_deny via rule osc_title_idle region osc_title in 0.4s (screen says idle, hook_source None)
PASS: smoke: codex denied command did not run (no /Users/matt/herdr-project/herdr-live-worktrees/m11/.superpowers/sdd/m11/tmp/smoke/run2/herdr-m11-codex)
PASS: smoke: codex exited, agent list no longer has p3
PASS: smoke: opencode idle via rule None region None in 3.4s (screen says idle, hook_source None)
PASS: smoke: opencode working via rule None region None in 0.2s (screen says working, hook_source herdr:opencode)
PASS: smoke: opencode idle_after_work via rule None region None in 35.4s (screen says idle, hook_source herdr:opencode)
PASS: smoke: opencode agent read and agent explain from inside pane p1 succeed
PASS: smoke: opencode blocked via rule None region None in 3.0s (screen says blocked, hook_source herdr:opencode)
PASS: smoke: opencode idle_after_deny via rule None region None in 0.4s (screen says idle, hook_source herdr:opencode)
PASS: smoke: opencode denied command did not run (no /Users/matt/herdr-project/herdr-live-worktrees/m11/.superpowers/sdd/m11/tmp/smoke/run2/herdr-m11-opencode)
PASS: smoke: opencode exited, agent list no longer has p4
PASS: quit: prefix q (detach) exits 0 (got 0)
PASS: quit: kitty flags popped, then the alt screen left
PASS: quit: tty settings unchanged
PASS: quit: log has herdr-live stopped

agent      version                    idle  working  blocked  deny->idle  hook_source  pass
claude     2.1.310 (Claude Code)      3.6   0.4      3.4      0.6         None         True
codex      codex-cli 0.164.0          3.3   0.4      7.4      0.4         None         True
opencode   opencode v2.0.22           3.4   0.2      3.0      0.4         herdr:opencode True
PASS: smoke: 3 agents reached idle, working and blocked (['claude', 'codex', 'opencode'])
results: /Users/matt/herdr-project/herdr-live-worktrees/m11/.superpowers/sdd/m11/tmp/smoke/run2/results.json
```
