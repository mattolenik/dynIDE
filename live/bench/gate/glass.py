#!/usr/bin/env python3
"""Keystroke -> glass through a real pty, for herdr (the Rust reference) and herdr-live.

Usage: glass.py herdr|herdr-live [--n 500] [--size 200x50] [--bin PATH]

The program runs attached as the session leader of a fresh WxH pty; this script is the
host terminal on the master. Startup probes (DA1, kitty ?u, DECRQM, OSC 10/11) are
answered. Once the pane's `$ ` prompt shows, the pane runs `exec cat` (echo by the tty
line discipline), then 1 s of quiet. Per sample: wait until no output for 30 ms, take
t0, write one char (a..z), read until that char appears in the bytes received after t0
with escape sequences stripped; sample = now - t0, i.e. until the bytes reach the host
pty master (the glass for both programs). Every 60 chars a `\\r`. A key with no echo in
2 s is a timeout. Prints one line:

  GLASS impl=<impl> size=WxH n=<n> p50_us=.. p95_us=.. p99_us=.. max_us=.. timeouts=..

and exits 1 if fewer than n/2 samples were taken. herdr runs isolated (XDG_CONFIG_HOME
and XDG_RUNTIME_DIR in a temp dir, config `onboarding = false`, `--session NAME`, stopped
and deleted afterwards);
herdr-live is launched like scripts/tty_harness.py's Herdr (bin/herdr-live, log in the
temp dir), quit with prefix q. The process groups started here are SIGKILLed on exit.
"""
import argparse
import fcntl
import os
import re
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

LIVE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(LIVE, "scripts"))
from tty_harness import PROBE, REPLY, Screen  # noqa: E402

ROOT = os.path.dirname(LIVE)
QUIET_S = 0.030
SETTLE_S = 1.0
KEY_TIMEOUT_S = 2.0
START_TIMEOUT_S = 600  # herdr-live's first start may compile
ENTER_EVERY = 60
# probes answered (one alternation, so the kitty+DA1 pair gets one REPLY); herdr's OSC 4
# palette queries are left to its own timeouts
PROBES = re.compile(re.escape(PROBE) + rb"|\x1b\[c|\x1b\[\?u|\x1b\[\?(\d+)\$p"
                    rb"|\x1b\](1[01]);\?(?:\x07|\x1b\\)")


def reply(m):
    if m.group(0) == PROBE:
        return REPLY
    if m.group(0) == b"\x1b[c":
        return b"\x1b[?62c"
    if m.group(0) == b"\x1b[?u":
        return b"\x1b[?0u"
    if m.group(1):
        return b"\x1b[?" + m.group(1) + b";0$y"
    return b"\x1b]" + m.group(2) + b";rgb:0000/0000/0000\x1b\\"


pgroups = set()


class Term:
    def __init__(self, argv, env, cols, rows):
        self.master, slave = os.openpty()
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        pid = os.fork()
        if pid == 0:
            try:
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
                for fd in (0, 1, 2):
                    os.dup2(slave, fd)
                os.close(self.master)
                os.execve(argv[0], argv, env)
            finally:
                os._exit(127)
        os.close(slave)
        self.pid = pid
        pgroups.add(pid)
        self.carry = b""
        self.alive = True
        self.reaped = False  # waitpid has collected the child
        self.hup = False  # the last read hit EIO with the child still running

    def read(self, wait):
        """One read of at most `wait` seconds; answers probes. Returns the bytes."""
        self.hup = False
        if not self.alive or not select.select([self.master], [], [], wait)[0]:
            return b""
        try:
            data = os.read(self.master, 65536)
        except OSError:
            data = b""
        if not data:
            # Linux gives EIO while no slave fd is open (herdr-live redirects its stdio to
            # the log before it opens /dev/tty, while it builds); macOS just blocks. Only a
            # child that has exited ends the session.
            if os.waitpid(self.pid, os.WNOHANG)[0] == 0:
                self.hup = True
                time.sleep(min(wait, 0.01))
                return b""
            self.reaped = True  # pgroups keeps the pid: the final killpg reaches survivors
            self.alive = False
            return b""
        self.answer(data)
        return data

    def answer(self, data):
        # a probe may be split across reads: rescan a short unanswered tail
        buf = self.carry + data
        end = 0
        for m in PROBES.finditer(buf):
            os.write(self.master, reply(m))
            end = m.end()
        self.carry = buf[max(end, len(buf) - 32):]

    def quiet(self, secs, cap):
        """Reads until no output for `secs` (at most `cap` seconds). True when quiet."""
        end = time.monotonic() + cap
        while time.monotonic() < end:
            if not self.read(secs) and not self.hup:
                return self.alive
        return False

    def until_text(self, text, timeout, label):
        seen, end = bytearray(), time.monotonic() + timeout
        while time.monotonic() < end:
            seen += self.read(0.05)
            if text in visible(seen):
                return
            if not self.alive:
                break
        sys.exit(f"glass: timed out waiting for {label}")

    def send(self, data):
        os.write(self.master, data)


def visible(data):
    """`data` decoded with escape sequences removed (a trailing partial one too)."""
    text = Screen.SEQ.sub("", data.decode("utf-8", "replace"))
    esc = text.rfind("\x1b")
    if esc >= 0 and Screen.PARTIAL.fullmatch(text, esc):
        text = text[:esc]
    return text


def base_env(tmp):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("HERDR_") and k not in ("ENV", "BASH_ENV")}
    env.update(SHELL="/bin/sh", PS1="$ ", HISTFILE="/dev/null", TERM="xterm-256color")
    return env


def herdr(tmp, bin_, cols, rows):
    name = f"glass{os.getpid()}"
    env = base_env(tmp)
    env.update(XDG_CONFIG_HOME=os.path.join(tmp, "xdg"), XDG_RUNTIME_DIR=os.path.join(tmp, "run"),
               HERDR_DISABLE_SOUND="1")
    os.makedirs(env["XDG_RUNTIME_DIR"], mode=0o700)
    # no first-run onboarding dialog over the pane
    os.makedirs(os.path.join(env["XDG_CONFIG_HOME"], "herdr"))
    with open(os.path.join(env["XDG_CONFIG_HOME"], "herdr", "config.toml"), "w") as f:
        f.write("onboarding = false\n")
    term = Term([bin_, "--session", name], env, cols, rows)

    def stop():
        ctl = {**env, "HERDR_SESSION": name}
        for cmd in ("stop", "delete"):
            subprocess.run([bin_, "session", cmd, name], env=ctl, capture_output=True, timeout=10)

    return term, stop


def herdr_live(tmp, bin_, cols, rows):
    env = base_env(tmp)
    env["HERDR_LIVE_LOG"] = os.path.join(tmp, "herdr-live.log")
    term = Term([bin_], env, cols, rows)

    def stop():
        term.send(b"\x02q")
        end = time.monotonic() + 10
        while time.monotonic() < end:
            term.read(0.05)
            if term.reaped or os.waitpid(term.pid, os.WNOHANG)[0]:
                pgroups.discard(term.pid)
                return

    return term, stop


def pct(sorted_, p):
    return sorted_[max(-(-p * len(sorted_) // 100) - 1, 0)] if sorted_ else 0


def measure(term, n):
    samples, timeouts = [], 0
    for i in range(n):
        if i and i % ENTER_EVERY == 0:
            term.send(b"\r")
        term.quiet(QUIET_S, KEY_TIMEOUT_S)
        ch = chr(ord("a") + i % 26)
        seen = bytearray()
        t0 = time.perf_counter_ns()
        term.send(ch.encode())
        end = t0 + int(KEY_TIMEOUT_S * 1e9)
        while True:
            data = term.read(max(end - time.perf_counter_ns(), 0) / 1e9)
            now = time.perf_counter_ns()
            seen += data
            if data and ch in visible(seen):
                samples.append((now - t0) // 1000)
                break
            if now >= end or not term.alive:
                timeouts += 1
                break
    return sorted(samples), timeouts


def main():
    ap = argparse.ArgumentParser(description="keystroke -> glass through a real pty")
    ap.add_argument("impl", choices=["herdr", "herdr-live"])
    ap.add_argument("--n", type=int, default=500)
    ap.add_argument("--size", default="200x50")
    ap.add_argument("--bin")
    args = ap.parse_args()
    m = re.fullmatch(r"(\d+)x(\d+)", args.size)
    if not m:
        sys.exit("glass: --size must be COLSxROWS")
    cols, rows = int(m.group(1)), int(m.group(2))
    launch, default = {
        "herdr": (herdr, os.path.join(ROOT, "target", "release", "herdr")),
        "herdr-live": (herdr_live, os.path.join(LIVE, "bin", "herdr-live")),
    }[args.impl]
    bin_ = os.path.abspath(args.bin or default)
    if not os.access(bin_, os.X_OK):
        sys.exit(f"glass: {bin_} is not executable")
    # short path: herdr's session socket lives under XDG_RUNTIME_DIR (sun_path limit)
    tmp = tempfile.mkdtemp(prefix="glass", dir="/var/tmp")
    stop = None
    try:
        term, stop = launch(tmp, bin_, cols, rows)
        term.until_text("$ ", START_TIMEOUT_S, "the pane's prompt")
        term.send(b"exec cat\r")
        if not term.quiet(SETTLE_S, 30):
            sys.exit("glass: no 1 s of quiet after exec cat")
        samples, timeouts = measure(term, args.n)
    finally:
        if stop:
            try:
                stop()
            except (OSError, subprocess.SubprocessError):
                pass
        for pg in pgroups:
            try:
                os.killpg(pg, signal.SIGKILL)
            except OSError:
                pass
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"GLASS impl={args.impl} size={cols}x{rows} n={len(samples)} p50_us={pct(samples, 50)} "
          f"p95_us={pct(samples, 95)} p99_us={pct(samples, 99)} "
          f"max_us={samples[-1] if samples else 0} timeouts={timeouts}")
    sys.exit(1 if len(samples) < args.n / 2 else 0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    main()
