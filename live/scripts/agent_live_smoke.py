#!/usr/bin/env python3
"""Live smoke with real agent CLIs (M11 exit criterion). NOT part of live-check:
it needs authenticated claude/codex/opencode on PATH and spends model tokens.

    python3 scripts/agent_live_smoke.py [-v] [OUT_DIR] [AGENT...]

Launches bin/herdr-live attached at 120x40 (tty_harness.Herdr: its own log, API
socket, runtime, state and config under OUT_DIR, default
../.superpowers/sdd/m11/tmp/smoke/run), HERDR_LIVE_PERSIST=0. Per agent: pane split,
pane run the CLI in a scratch cwd, then agent wait idle -> prompt -> working -> idle
-> prompt to run `touch` -> blocked -> esc (deny) -> idle -> ctrl+c twice -> agent
list shrinks. At each state it records agent get and agent explain --json (matched
rule, region, evidence preview); a missed state records explain and pane read
--source recent instead. From the first pane's shell it runs "$HERDR_LIVE_BIN" agent
read / agent explain against the agent pane (the from-inside-a-pane check).
Exits 1 when fewer than two agents reach idle, working and blocked.
"""
import json
import os
import shutil
import signal
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tty_harness as th  # noqa: E402

ROOT = os.path.dirname(th.LIVE)
CODEX = "/opt/homebrew/Caskroom/codex/0.164.0/bin/codex"
# The launch line per agent. claude: the user's settings default to auto mode, which
# would not ask. codex: on-request approvals in a read-only sandbox with the user (not
# the config's auto reviewer) answering, so a write asks. opencode: its default bash
# permission is allow (it ran the touch); --standalone runs a private server (not the
# user's background service) so the env config that makes bash ask applies.
AGENTS = {
    "claude": ("claude", "claude --permission-mode default"),
    "codex": (CODEX, f"{CODEX} -s read-only -a on-request -c approvals_reviewer=\\\"user\\\""),
    "opencode": ("opencode", "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"bash\":\"ask\"}}' opencode --standalone"),
}
WORK_PROMPT = "Explain in about 300 words how a terminal multiplexer works. Do not use any tools."
# startup dialogs answered with enter (first option: trust / continue)
STARTUP = ("Do you trust", "trust this folder", "Trust this", "trust the files")

results = {}


def say(cond, msg):
    print(f"{'PASS' if cond else 'FAIL'}: {msg}", flush=True)
    return cond


def pump_for(h, secs):
    end = time.monotonic() + secs
    while time.monotonic() < end:
        th.pump_all()


def cli(h, *args, timeout=150):
    return h.cli(*args, timeout=timeout)


def js(h, *args, timeout=150):
    rc, out = cli(h, *args, timeout=timeout)
    try:
        return rc, json.loads(out)
    except ValueError:
        return rc, {"raw": out}


def explain(h, pane):
    rc, ex = js(h, "agent", "explain", pane, "--json")
    ex = ex.get("agent", ex) if isinstance(ex, dict) else ex
    m = (ex or {}).get("matched_rule") or {}
    ev = next((r["evidence"] for r in ex.get("evaluated_rules", []) if r.get("id") == m.get("id")), {})
    return {"rc": rc, "state": ex.get("state"), "rule": m.get("id"), "region": m.get("region"),
            "manifest_source": ex.get("manifest_source"), "fallback": ex.get("fallback_reason"),
            "preview": ev.get("region_preview"), "raw": ex}


def snapshot(h, pane):
    _, got = js(h, "agent", "get", pane)
    return {"get": got.get("agent", got), "explain": explain(h, pane)}


def wait(h, pane, states, timeout_ms):
    """agent wait in 3 s slices (the CLI call pumps the pty meanwhile; a pane not yet
    identified as an agent answers not_found); returns the elapsed seconds or None."""
    t0, end = time.monotonic(), time.monotonic() + timeout_ms / 1000
    args = [a for s in states for a in ("--until", s)]
    while time.monotonic() < end:
        rc, out = cli(h, "agent", "wait", pane, *args, "--timeout", "3000")
        if rc == 0:
            return round(time.monotonic() - t0, 1)
        if '"not_found"' in out:
            pump_for(h, 0.5)
    return None


def evidence(h, pane):
    _, read = cli(h, "pane", "read", pane, "--source", "recent", "--lines", "60")
    return {"explain": explain(h, pane)["raw"], "pane_read_recent": read}


def pane_run_file(h, pane, cmd, done, tmp, timeout=60):
    """Runs `cmd` in pane `pane`'s shell, then waits for `touch done`."""
    path = os.path.join(tmp, done)
    cli(h, "pane", "run", pane, f"{cmd}; touch {path}")
    end = time.monotonic() + timeout
    while not os.path.exists(path) and time.monotonic() < end:
        th.pump_all()
    return os.path.exists(path)


def smoke(h, name, tmp, first):
    exe, line = AGENTS[name]
    r = results[name] = {"states": {}, "times": {}, "ok": {}, "notes": []}
    r["version"] = subprocess.run([shutil.which(exe) or exe, "--version"], capture_output=True,
                                  text=True, timeout=30).stdout.strip()
    work = os.path.join(tmp, f"work-{name}")
    os.makedirs(work, exist_ok=True)
    marker = os.path.join(tmp, f"herdr-m11-{name}")
    _, split = js(h, "pane", "split", first, "--direction", "right")
    pane = split["pane"]["pane_id"]
    r["pane"] = pane
    _, info = js(h, "pane", "process-info", pane)
    r["shell_pid"] = info.get("os_pid")
    cli(h, "pane", "run", pane, f"cd {work} && {line}")

    def tail(lines=14):
        return cli(h, "pane", "read", pane, "--lines", str(lines))[1]

    def record(state, secs, label):
        r["times"][label] = secs
        r["ok"][label] = False
        if secs is None:
            say(False, f"smoke: {name} {label} not reached")
            r["states"][label] = {"miss": evidence(h, pane)}
            return False
        s = r["states"][label] = snapshot(h, pane)
        s["screen"] = tail(30)
        ex = s["explain"]
        r["ok"][label] = say(s["get"].get("agent_status") in state,
                             f"smoke: {name} {label} via rule {ex['rule']} region {ex['region']} in {secs}s"
                             f" (screen says {ex['state']}, hook_source {s['get'].get('hook_source')})")
        return r["ok"][label]

    def settle(label, timeout_ms):
        """Waits for idle; a dialog on the way (blocked, or text before detection) is
        recorded and answered: enter for a startup trust prompt, esc for anything else."""
        t0, end = time.monotonic(), time.monotonic() + timeout_ms / 1000
        while time.monotonic() < end:
            left = int((end - time.monotonic()) * 1000)
            got = wait(h, pane, ["idle", "done", "blocked"], max(left, 1000))
            if got is None:
                break
            _, a = js(h, "agent", "get", pane)
            if a.get("agent", {}).get("agent_status") != "blocked":
                return record(("idle", "done"), round(time.monotonic() - t0, 1), label)
            ex, txt = explain(h, pane), tail()
            key = "enter" if any(k in txt for k in STARTUP) else "esc"
            r["notes"].append({"at": label, "dialog_blocked_via": ex["rule"], "region": ex["region"],
                               "answered": key, "screen": txt})
            print(f"NOTE: smoke: {name} {label}: dialog read as blocked via {ex['rule']}, answered {key}")
            cli(h, "agent", "send-keys", pane, key)
            pump_for(h, 1.5)
        return record(("idle", "done"), None, label)

    if not settle("idle", 90000):
        return pane
    marker_before = os.path.exists(marker)
    cli(h, "agent", "prompt", pane, WORK_PROMPT)
    record(("working",), wait(h, pane, ["working"], 30000), "working")
    settle("idle_after_work", 180000)

    # from inside a pane: the first pane's shell reads and explains the agent pane
    bin_ = '"$HERDR_LIVE_BIN"'
    o1, o2 = os.path.join(tmp, f"{name}-read.txt"), os.path.join(tmp, f"{name}-explain.txt")
    ran = pane_run_file(h, first, f"{bin_} agent read {pane} --lines 20 > {o1} 2>&1; echo rc=$? >> {o1}"
                        f"; {bin_} agent explain {pane} > {o2} 2>&1; echo rc=$? >> {o2}", f"{name}-in", tmp)
    rd, xp = (open(o1).read(), open(o2).read()) if ran else ("", "")
    r["inside"] = {"read": rd, "explain": xp}
    say(ran and rd.rstrip().endswith("rc=0") and xp.rstrip().endswith("rc=0"),
        f"smoke: {name} agent read and agent explain from inside pane {first} succeed")

    cli(h, "agent", "prompt", pane, f"Run exactly this shell command and nothing else: touch {marker}")
    blocked = record(("blocked",), wait(h, pane, ["blocked"], 90000), "blocked")
    if blocked:
        _, r["blocked_screen"] = cli(h, "pane", "read", pane, "--lines", "25")
        cli(h, "agent", "send-keys", pane, "esc")
        settle("idle_after_deny", 60000)
        r["marker_created"] = os.path.exists(marker) and not marker_before
        say(not r["marker_created"], f"smoke: {name} denied command did not run (no {marker})")
    # exit the agent: ctrl+c twice, then /exit; the pane's agent goes away
    gone = False
    for how in ("ctrl+c", "/exit"):
        if how == "ctrl+c":
            cli(h, "agent", "send-keys", pane, "ctrl+c")
            pump_for(h, 0.3)
            cli(h, "agent", "send-keys", pane, "ctrl+c")
        else:
            cli(h, "pane", "run", pane, "/exit")
        end = time.monotonic() + 10
        while time.monotonic() < end and not gone:
            _, lst = js(h, "agent", "list")
            gone = pane not in [a.get("pane_id") for a in lst.get("agents", [])]
            if not gone:
                pump_for(h, 0.5)
        if gone:
            break
    r["exited"] = gone
    r["exit_screen"] = tail(8)
    say(gone, f"smoke: {name} exited, agent list no longer has {pane}")
    r["pass"] = all(r["ok"].get(k) for k in ("idle", "working", "blocked"))
    return pane


def main():
    args = [a for a in sys.argv[1:] if a != "-v"]
    if os.environ.get("HERDR_BROKER_SOCK"):
        print("BLOCKED: running inside herdr-live; run from another terminal")
        sys.exit(2)
    tmp = os.path.abspath(args.pop(0)) if args and "/" in args[0] else \
        os.path.join(ROOT, ".superpowers", "sdd", "m11", "tmp", "smoke", "run")
    names = [a for a in args if a in AGENTS] or [n for n, (exe, _) in AGENTS.items() if shutil.which(exe)]
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    # the launched instance must not see a surrounding herdr (or herdr-live) session
    # nor the Claude Code session that may run this script (its CLAUDE* markers)
    for k in [k for k in os.environ if k.startswith(("HERDR_", "CLAUDE")) or k == "TERM_PROGRAM"]:
        del os.environ[k]
    os.environ["HERDR_LIVE_PERSIST"] = "0"
    # th.Herdr sets its own HERDR_LIVE_STATE_DIR per run; this default keeps any other launch isolated too
    os.environ["HERDR_LIVE_STATE_DIR"] = os.path.join(tmp, "state")
    th.compile_then_start_clock(tmp)
    th.DEADLINE = time.monotonic() + 3600
    h = th.Herdr(tmp, 120, 40)
    h.start()
    _, lst = js(h, "pane", "list")
    first = lst["panes"][0]["pane_id"]
    child_pids = []
    for name in names:
        pane = smoke(h, name, tmp, first)
        child_pids += descendants(results[name].get("shell_pid"))
        cli(h, "pane", "close", pane)
        pump_for(h, 1)
    h.quit()
    for pid in child_pids:  # pane shells we know of, should the server have left any
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass
    with open(os.path.join(tmp, "results.json"), "w") as f:
        json.dump(results, f, indent=2, default=str)
    print("\nagent      version                    idle  working  blocked  deny->idle  hook_source  pass")
    for n, r in results.items():
        t, g = r["times"], (r["states"].get("blocked") or r["states"].get("idle") or {}).get("get", {})
        print(f"{n:10} {r['version'][:26]:26} {t.get('idle')!s:5} {t.get('working')!s:8} {t.get('blocked')!s:8}"
              f" {t.get('idle_after_deny')!s:11} {g.get('hook_source')!s:12} {r.get('pass')}")
    passed = [n for n, r in results.items() if r.get("pass")]
    say(len(passed) >= 2, f"smoke: {len(passed)} agents reached idle, working and blocked ({passed})")
    print(f"results: {os.path.join(tmp, 'results.json')}")
    sys.exit(0 if len(passed) >= 2 else 1)


def descendants(root):
    """The pids under `root` (the pane shell), the shell included."""
    if not root:
        return []
    rows = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True).stdout.split()
    kids, found = {}, [root]
    for pid, ppid in zip(rows[::2], rows[1::2]):
        kids.setdefault(int(ppid), []).append(int(pid))
    for p in found:
        found += kids.get(p, [])
    return found


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        main()
    finally:
        th.kill_all()
