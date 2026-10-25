#!/usr/bin/env python3
"""Reflow check: the same pane script in herdr (the herdr-reference build, via
bench/gate/herdr_ref.sh, or HERDR_BIN) and in herdr-live, each attached in a 120x40 pty:
print a 307-char line (no soft-wrap ambiguity at
120, 93, 60 or 59 columns) and 20 numbered lines between markers, resize the pty to 60x40,
then back to 120x40, and read the pane text between the markers (content columns
only: the chrome around the pane is cut off).

Prints `PASS reflow ...` when both show the same logical lines (soft-wrapped rows
joined, so differing pane widths compare) and each pane's final rows equal its own
rows before the resize; otherwise the exact differences are listed. Exit 1 on a
difference or a failed launch. Skips (SKIP, exit 0) inside a herdr-live pane.

Usage: reflow.py [-v]
"""
import fcntl
import importlib.util
import os
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

HERE = os.path.dirname(os.path.abspath(__file__))
LIVE = os.path.dirname(os.path.dirname(HERE))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


th = load("tty_harness", os.path.join(LIVE, "scripts", "tty_harness.py"))
glass = load("glass", os.path.join(LIVE, "bench", "gate", "glass.py"))
verbose = "-v" in sys.argv
TIMEOUT = 300  # host load can be very high
SCRIPT = (b"printf '%s\\n' R''-BEGIN; printf '%s' 0123456789"
          b" 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789"
          b" 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789"
          b" 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789"
          b" 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789 0123456789"
          b" 0123456789 0123456; echo; i=1; while [ $i -le 20 ]; do echo \"line $i\"; i=$((i + 1)); done;"
          b" printf '%s\\n' R''-END\r")


class Failed(Exception):
    pass


class Driver:
    """A pty program (glass.Term) with a th.Screen fed from its output."""

    def __init__(self, term, stop):
        self.term, self.stop, self.screen = term, stop, th.Screen()

    def pump(self, wait=0.05):
        data = self.term.read(wait)
        if data:
            self.screen.feed(data)

    def until(self, check, label, timeout=TIMEOUT):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            got = check()
            if got:
                return got
            self.pump()
        if verbose:
            print("--- screen", self.screen.text(), sep="\n")
        raise Failed(f"timed out waiting for {label}")

    def settle(self, quiet=1.0, cap=30):
        end = time.monotonic() + cap
        while time.monotonic() < end:
            data = self.term.read(quiet)
            if not data and not self.term.hup:
                return
            self.screen.feed(data)

    def resize(self, cols, rows):
        # a fresh model: both programs repaint the whole screen on SIGWINCH, and a
        # model kept at the old size would hold cells the host no longer has
        self.screen = th.Screen()
        fcntl.ioctl(self.term.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def content(screen):
    """The pane rows between the R-BEGIN and R-END output rows, cut to the pane's
    columns (from the column of R-BEGIN to the end of the widest digit run),
    plus that width."""
    rows = screen.rows()
    begin = next((y for y, r in enumerate(rows) if r.rstrip().endswith("R-BEGIN") and "printf" not in r), None)
    end = next((y for y, r in enumerate(rows) if y > (begin or 0) and r.rstrip().endswith("R-END")
                and "printf" not in r), None)
    if begin is None or end is None:
        return None
    x0 = rows[begin].index("R-BEGIN")
    body = rows[begin + 1:end]
    width = max(len(r[x0:]) - len(r[x0:].lstrip("0123456789")) for r in body)
    return [r[x0:x0 + width].rstrip() for r in body], width


def logical(lines, width):
    """Rows joined where a row fills the whole width (a soft wrap)."""
    out, cur = [], ""
    for r in lines:
        cur += r
        if len(r) < width:
            out.append(cur)
            cur = ""
    if cur:
        out.append(cur)
    return out


def run(name, launch):
    """Launches, runs the script, resizes 120x40 -> 60x40 -> 120x40; returns
    (rows before, rows after, width before, width after)."""
    d = Driver(*launch())
    try:
        d.until(lambda: "$ " in d.screen.text(), f"{name}: the pane's prompt")
        d.settle()
        d.term.send(SCRIPT)
        got = d.until(lambda: content(d.screen), f"{name}: the script's output")
        d.settle()
        before = content(d.screen)
        d.resize(60, 40)
        d.until(lambda: (c := content(d.screen)) and c[1] < before[1], f"{name}: the 60-column repaint")
        d.settle()
        narrow = content(d.screen)
        d.resize(120, 40)
        d.until(lambda: (c := content(d.screen)) and c[1] > narrow[1], f"{name}: the 120-column repaint")
        d.settle()
        after = content(d.screen)
        if verbose:
            print(f"--- {name} screen", d.screen.text(), sep="\n")
        return before, narrow, after, got
    finally:
        try:
            d.stop()
        except (OSError, subprocess.SubprocessError):
            pass


def herdr(tmp, bin_):
    os.makedirs(tmp)
    return glass.herdr(tmp, bin_, 120, 40)  # isolated config, runtime dir and session


def herdr_live(tmp):
    os.makedirs(tmp)
    h = th.Herdr(tmp, 120, 40)  # isolated log, API socket, runtime and state dirs
    term = glass.Term.__new__(glass.Term)
    term.master, term.pid, term.carry = h.master, h.pid, b""
    term.alive, term.reaped, term.hup = True, False, False
    glass.pgroups.add(h.pid)

    def stop():
        term.send(b"\x02q")
        end = time.monotonic() + 30
        while time.monotonic() < end and not term.reaped and not os.waitpid(h.pid, os.WNOHANG)[0]:
            term.read(0.05)

    return term, stop


def main():
    th.compile_then_start_clock(tempfile.mkdtemp(prefix="reflowc", dir="/var/tmp"))
    th.DEADLINE = time.monotonic() + 3600
    th.fail = lambda msg: (_ for _ in ()).throw(Failed(msg))
    bin_ = subprocess.check_output([os.path.join(LIVE, "bench", "gate", "herdr_ref.sh")], text=True).strip()
    tmp = tempfile.mkdtemp(prefix="reflow", dir="/var/tmp")  # short: herdr's socket path
    try:
        ref = run("herdr", lambda: herdr(os.path.join(tmp, "h"), bin_))
        live = run("herdr-live", lambda: herdr_live(os.path.join(tmp, "l")))
    except Failed as e:
        print(f"FAIL reflow: {e}")
        return 1
    finally:
        for pg in glass.pgroups | th.pgroups:
            try:
                os.killpg(pg, signal.SIGKILL)
            except OSError:
                pass
        shutil.rmtree(tmp, ignore_errors=True)
    diffs = []
    for name, (before, narrow, after, _) in (("herdr", ref), ("herdr-live", live)):
        if after != before:
            diffs.append(f"{name}: rows after 120->60->120 differ from before: {before[0]!r} vs {after[0]!r}")
        if logical(*narrow) != logical(*before):
            diffs.append(f"{name}: logical lines at {narrow[1]} cols differ: {logical(*narrow)!r}")
    lr, ll = logical(*ref[2]), logical(*live[2])
    if lr != ll:
        diffs.append(f"herdr vs herdr-live logical lines: {lr!r} vs {ll!r}")
    widths = f"pane widths herdr {ref[0][1]}/{ref[1][1]}/{ref[2][1]}, herdr-live {live[0][1]}/{live[1][1]}/{live[2][1]}"
    if diffs:
        print(f"FAIL reflow: {widths}; differences:")
        for d in diffs:
            print(f"  - {d}")
        return 1
    print(f"PASS reflow equal to herdr: {len(ll)} logical lines, the 307-char line rewrapped at the narrow "
          f"width and restored, {widths}")
    return 0


if __name__ == "__main__":
    if os.environ.get("HERDR_BROKER_SOCK"):
        print("SKIP: reflow: running inside herdr-live (run it outside, see editing-live.md)")
        sys.exit(0)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    sys.exit(main())
