# M11 manual checklist (human): agent detection

The scripted checks and the live smoke ([m11-smoke.md](m11-smoke.md)) cannot judge what the
sidebar and toasts look and feel like with a real agent. This checklist covers those. Run
`just live-run` in a GUI terminal, outside any other herdr-live instance. Needs `claude`
(or codex/opencode) installed and signed in.

```
terminal:            version:            OS:            agent + version:            commit:            date:
```

Conventions: `[ ] pass  [ ] fail`. Prefix is `ctrl-b`; `ctrl-b c` new tab, `ctrl-b q` quits.

## A. Badges

| # | Step | Expect | Result |
|---|---|---|---|
| A1 | Split a pane, run `claude` and wait at its prompt | the sidebar shows the agent with an idle badge | [ ] pass  [ ] fail |
| A2 | Send a prompt that takes more than 5 s | badge turns working within about a second | [ ] pass  [ ] fail |
| A3 | Ask it to run a shell command so it asks permission | badge turns blocked | [ ] pass  [ ] fail |
| A4 | Deny (Esc); let a working turn finish in a background tab | badge shows done (finished, unseen), distinct from idle | [ ] pass  [ ] fail |
| A5 | Switch to the tab holding the done pane | the done badge turns idle | [ ] pass  [ ] fail |
| A6 | Exit the agent (ctrl+c twice) | the agent label and badge go away within a few seconds | [ ] pass  [ ] fail |

## B. Toasts

| # | Step | Expect | Result |
|---|---|---|---|
| B1 | Start a long prompt in a background tab and stay elsewhere | after it finishes, a toast appears about 1 s later | [ ] pass  [ ] fail |
| B2 | Make a background agent ask for permission | a toast appears about 1 s later | [ ] pass  [ ] fail |
| B3 | Look at the agent's tab, focused, while it finishes or blocks | no toast | [ ] pass  [ ] fail |
| B4 | Finish and immediately switch to the tab inside the delay | no toast (re-check drops it) | [ ] pass  [ ] fail |

## C. Sort and Go-to

| # | Step | Expect | Result |
|---|---|---|---|
| C1 | With two or more agents, click the sort button in the agents section | text toggles `grouped` / `priority`; priority orders blocked > done > working > idle | [ ] pass  [ ] fail |
| C2 | Open Go-to, press Tab repeatedly | the filter cycles all, blocked, working, idle, done and the list narrows; typed text is kept | [ ] pass  [ ] fail |
| C3 | Collapse the sidebar | the sort label is hidden | [ ] pass  [ ] fail |

## D. Explain from inside a pane

| # | Step | Expect | Result |
|---|---|---|---|
| D1 | In a second pane, with claude asking permission in the first: `"$HERDR_LIVE_BIN" agent list` then `agent explain <id>` | state blocked, a rule such as `bash_permission_prompt`, evidence text, manifest source | [ ] pass  [ ] fail |
| D2 | `"$HERDR_LIVE_BIN" agent read <id> --lines 20` | the agent's last lines | [ ] pass  [ ] fail |

## E. Override manifest hot reload

| # | Step | Expect | Result |
|---|---|---|---|
| E1 | `mkdir -p ~/.config/herdr-live/agent-detection && cp live/apps/herdr_server/priv/detect/manifests/claude.toml ~/.config/herdr-live/agent-detection/` | file exists | [ ] pass  [ ] fail |
| E2 | Edit a rule id (or break a pattern) in the copy and save | within about a second `agent explain <id>` shows the new rule id / the override as the manifest source, no restart | [ ] pass  [ ] fail |
| E3 | Write invalid TOML and save | explain warns `ignored override ...` and the bundled manifest still drives detection | [ ] pass  [ ] fail |
| E4 | Delete the override | explain returns to the bundled manifest | [ ] pass  [ ] fail |

## F. Kernel restart

| # | Step | Expect | Result |
|---|---|---|---|
| F1 | With an agent running, `live/bin/herdr-live kernel-restart` | the agent pane survives; its badge keeps updating (send a prompt: working, then idle/done) | [ ] pass  [ ] fail |

Notes:

## Sign-off

- [ ] Every step above passed, or each failure is recorded in the notes with the step id.
- Verdict: ______  Signed: ______  Date: ______
