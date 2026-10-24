#!/usr/bin/env python3
"""Summarise herdr-live telemetry (`herdr-event <kind> ts=<ms> k=v ...`) from log files.

Usage: log_summary.py [LOG ...] [--since ISO8601] [--json]
Default log: $HERDR_LIVE_LOG, else ${XDG_STATE_HOME:-~/.local/state}/herdr-live/herdr-live.log.
Exit 0 unless a log is unreadable (exit 2).
"""
import argparse
import json
import os
import re
import sys
from collections import Counter
from datetime import datetime, timezone

HEAD = re.compile(r"herdr-event ([A-Za-z0-9_]+) ts=(\d+)(?=\s|$)")
PAIR = re.compile(r'\s+([A-Za-z0-9_]+)=("(?:[^"\\]|\\.)*"|[^\s"]*)(?=\s|$)')


def parse_line(line):
    """Return (kind, ts_ms, fields) for the first event on the line, None if no event
    marker, or False when the marker is present but the line is malformed."""
    if "herdr-event" not in line:
        return None
    m = HEAD.search(line)
    if not m:
        return False
    fields, pos, line = {}, m.end(), line.rstrip("\r\n")
    while pos < len(line):
        p = PAIR.match(line, pos)
        if not p:
            if line[pos:].strip():
                return False
            break
        v = p.group(2)
        if v.startswith('"'):
            v = re.sub(r"\\(.)", r"\1", v[1:-1])
        fields[p.group(1)] = v
        pos = p.end()
    return m.group(1), int(m.group(2)), fields


def default_log():
    env = os.environ.get("HERDR_LIVE_LOG")
    if env:
        return env
    state = os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state")
    return os.path.join(state, "herdr-live", "herdr-live.log")


def read_events(paths, since_ms=None):
    events, unparsed = [], 0
    for path in paths:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                r = parse_line(line)
                if r is False:
                    unparsed += 1
                elif r is not None and (since_ms is None or r[1] >= since_ms):
                    events.append(r)
    return events, unparsed


def pct(sorted_vals, p):
    if not sorted_vals:
        return None
    return sorted_vals[max(0, -(-len(sorted_vals) * p // 100) - 1)]


def to_int(v, default=0):
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def iso(ms):
    return datetime.fromtimestamp(ms / 1000, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def summarize(events, unparsed=0):
    c = Counter()
    rb_reasons, crashes, hand_ms = Counter(), Counter(), []
    fanout_max = modules = 0
    syncs = 0
    broker_up = False
    for kind, _ts, f in events:
        if kind == "vm_start":
            c["vm_starts"] += 1
        elif kind == "reload":
            c["reloads"] += 1
            fan = to_int(f.get("fanout"), len([m for m in f.get("modules", "").split(",") if m]))
            modules += fan
            fanout_max = max(fanout_max, fan)
        elif kind == "compile_error":
            c["compile_errors"] += 1
        elif kind == "rollback":
            reason = f.get("reason", "other")
            c["rb_manual" if reason == "manual" else "rb_auto"] += 1
            rb_reasons[reason] += 1
        elif kind == "guard_failure":
            c["gf_none" if f.get("attributed", "none") == "none" else "gf_attr"] += 1
        elif kind == "tests":
            if f.get("result") == "passed":
                c["t_pass"] += 1
            elif f.get("result") in ("failed", "error"):
                c["t_fail"] += 1
            elif f.get("result") == "stale":
                c["t_stale"] += 1
        elif kind == "sync":
            syncs += to_int(f.get("count"))
        elif kind == "broker_handoff":
            c["h_graceful" if f.get("kind") == "graceful" else "h_crash"] += 1
            if "ms" in f:
                hand_ms.append(to_int(f["ms"]))
        elif kind == "broker_handoff_failed":
            c["h_failed"] += 1
        elif kind == "crash":
            crashes[f.get("proc", "unknown")] += 1
            # the Store restarted from the mirror: the layout was kept, not a loss
            if f.get("proc") == "store" and f.get("action") == "restored":
                c["store_restarts"] += 1
        elif kind == "session_lost":
            c["session_losses"] += 1
        elif kind == "broker_start":
            # a start with no broker_stop since the last start: the broker died, and its
            # children with it (reason broker_died)
            if broker_up:
                c["session_losses"] += 1
            broker_up = True
        elif kind == "broker_stop":
            broker_up = False
        elif kind == "persist_restore":
            if f.get("source") == "disk":
                c["r_disk"] += 1
                c["r_fallback" if f.get("reason") == "fallback" else "r_boot"] += 1
            else:
                c["r_none"] += 1
        elif kind == "persist_write":
            c["persist_writes"] += 1
        elif kind == "persist_error":
            c["persist_errors"] += 1
    hand_ms.sort()
    stamps = [e[1] for e in events]
    return {
        "period": f"{iso(min(stamps))} .. {iso(max(stamps))}" if stamps else "none",
        "vm_starts": c["vm_starts"],
        "reloads": c["reloads"],
        "modules_reloaded": modules,
        "fanout_max": fanout_max,
        "compile_errors": c["compile_errors"],
        "rollbacks": {"manual": c["rb_manual"], "auto": c["rb_auto"]},
        "rollback_reasons": dict(sorted(rb_reasons.items())),
        "guard_failures": {"attributed": c["gf_attr"], "unattributed": c["gf_none"]},
        "tests": {"passed": c["t_pass"], "failed": c["t_fail"], "stale": c["t_stale"]},
        "syncs": {"modules": syncs},
        "handoffs": {"crash": c["h_crash"], "graceful": c["h_graceful"], "failed": c["h_failed"]},
        "handoff_ms_p50": pct(hand_ms, 50),
        "handoff_ms_p95": pct(hand_ms, 95),
        "handoff_ms_max": hand_ms[-1] if hand_ms else None,
        "crashes": dict(sorted(crashes.items())),
        "store_restarts": c["store_restarts"],
        "restores": {"disk": c["r_disk"], "boot": c["r_boot"], "fallback": c["r_fallback"],
                     "none": c["r_none"]},
        "persist_writes": c["persist_writes"],
        "persist_errors": c["persist_errors"],
        "session_losses": c["session_losses"],
        "unparsed": unparsed,
    }


def kv(d, suffix=""):
    return ", ".join(f"{k} {v}" for k, v in d.items()) if d else "none"


def render_text(s):
    n = s["session_losses"]
    na = lambda v: "n/a" if v is None else v
    rows = [
        ("period", s["period"]),
        ("vm_starts", s["vm_starts"]),
        ("reloads", s["reloads"]),
        ("modules_reloaded", s["modules_reloaded"]),
        ("fanout_max", s["fanout_max"]),
        ("compile_errors", s["compile_errors"]),
        ("rollbacks", kv(s["rollbacks"])),
        ("rollback_reasons", kv({k: v for k, v in s["rollback_reasons"].items()})),
        ("guard_failures", kv(s["guard_failures"])),
        ("tests", kv(s["tests"])),
        ("syncs", f"{s['syncs']['modules']} modules"),
        ("handoffs", kv(s["handoffs"])),
        ("handoff_ms_p50", na(s["handoff_ms_p50"])),
        ("handoff_ms_p95", na(s["handoff_ms_p95"])),
        ("handoff_ms_max", na(s["handoff_ms_max"])),
        ("crashes", kv(s["crashes"])),
        ("store_restarts", s["store_restarts"]),
        ("restores", "disk={disk} (boot={boot} fallback={fallback}) none={none}".format(**s["restores"])),
        ("persist_writes", s["persist_writes"]),
        ("persist_errors", s["persist_errors"]),
        ("session_losses", n),
        ("unparsed", s["unparsed"]),
        ("exit_criterion", f"session_losses=0 -> {'OK' if n == 0 else f'FAIL ({n})'}"),
    ]
    return "\n".join(f"{k}: {v}" for k, v in rows)


def parse_since(text):
    dt = datetime.fromisoformat(text.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp() * 1000)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("logs", nargs="*", metavar="LOG")
    ap.add_argument("--since", help="ISO8601; naive times are UTC")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    try:
        since = parse_since(a.since) if a.since else None
    except ValueError:
        ap.error(f"bad --since: {a.since}")
    try:
        events, unparsed = read_events(a.logs or [default_log()], since)
    except OSError as e:
        print(f"log_summary: {e}", file=sys.stderr)
        return 2
    s = summarize(events, unparsed)
    print(json.dumps(s) if a.json else render_text(s))
    return 0


if __name__ == "__main__":
    sys.exit(main())
