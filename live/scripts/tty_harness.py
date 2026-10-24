#!/usr/bin/env python3
"""End-to-end host tty checks for HerdrTerm.Native.Tty under a real pty.

Usage: tty_harness.py destructor|demo [-v]

destructor: runs scripts/tty_destructor.exs in the BEAM as the pty's session
leader. Answers each kitty/DA1 probe, then checks: the destructor of a killed
owner restores the tty; an invalid row is {:error, :bad_frame}; Tty.suspend
leaves the alt screen in cooked mode while the VM is stopped and, after
SIGCONT, is raw again, re-enters the alt screen, re-pushes kitty flags and
repaints fully.

demo: drives bin/live-demo as a job of an interactive /bin/sh (job control on)
in a pty: first paint, input, Ctrl-Z / fg with full repaint, SIGWINCH resize,
kill -9 of the VM (the wrapper restores the tty), and `q` exiting 0.

Prints PASS lines; exits 1 on the first failure. Every mode SIGKILLs the
process groups it started on any exit, including Ctrl-C. The 120 s deadline
starts after `mix compile` (itself capped at COMPILE_TIMEOUT seconds).
"""
import fcntl
import os
import pty
import re
import struct
import select
import signal
import subprocess
import sys
import tempfile
import termios
import time
import unicodedata

LIVE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUN_SECONDS = 120
COMPILE_TIMEOUT = 600
DEADLINE = None
PROBE = b"\x1b[?u\x1b[c"
REPLY = b"\x1b[?0u\x1b[?62c"
COOKED = termios.ICANON | termios.ECHO
verbose = "-v" in sys.argv
transcript = bytearray()
# Process groups to SIGKILL when a mode ends (SIGKILL also ends stopped ones).
pgroups = set()


def kill_all():
    for pg in pgroups:
        try:
            os.killpg(pg, signal.SIGKILL)
        except OSError:
            pass
    pgroups.clear()


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    if verbose:
        print("--- transcript", repr(bytes(transcript)), sep="\n")
    sys.exit(1)


def ok(cond, msg):
    if not cond:
        fail(msg)
    print(f"PASS: {msg}")


def lflag(fd):
    return termios.tcgetattr(fd)[3]


def config(fd):
    # PENDIN is BSD tty bookkeeping set when ICANON is re-enabled, not config.
    # Read via the master: macOS revokes the slave once the session leader exits.
    attrs = termios.tcgetattr(fd)
    attrs[3] &= ~getattr(termios, "PENDIN", 0)
    return attrs


def compile_then_start_clock(tmp):
    global DEADLINE
    log = os.path.join(tmp, "compile.log")
    with open(log, "w") as out:
        try:
            built = subprocess.run(["mix", "compile"], cwd=LIVE, stdout=out, stderr=out,
                                   timeout=COMPILE_TIMEOUT)
        except subprocess.TimeoutExpired:
            fail(f"mix compile took over {COMPILE_TIMEOUT} s")
    if built.returncode != 0:
        fail(f"mix compile failed: {open(log).read()[-2000:]}")
    DEADLINE = time.monotonic() + RUN_SECONDS


def drain(master, wait):
    """Reads into the transcript until the master is idle for `wait` seconds."""
    while select.select([master], [], [], wait)[0] and time.monotonic() < DEADLINE:
        try:
            data = os.read(master, 65536)
        except OSError:
            return
        if not data:
            return
        transcript.extend(data)


def spawn(master, slave, env):
    pid = os.fork()
    if pid == 0:
        try:
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
            # stdin away from the tty, so only the NIF reader takes its input.
            os.dup2(os.open(os.devnull, os.O_RDONLY), 0)
            os.dup2(slave, 1)
            os.dup2(slave, 2)
            os.close(master)
            os.chdir(LIVE)
            os.execvpe("mix", ["mix", "run", "--no-start", "scripts/tty_destructor.exs"], env)
        finally:
            os._exit(127)
    return pid


def destructor():
    with tempfile.TemporaryDirectory() as tmp:
        compile_then_start_clock(tmp)
        result = os.path.join(tmp, "result")
        master, slave = os.openpty()
        before = config(master)
        child = spawn(master, slave, {**os.environ, "TTY_RESULT": result, "TTY_PATH": os.ttyname(slave)})
        pgroups.add(child)  # setsid: the child leads its own process group

        answered, status = 0, None
        stop_at = resume_at = None
        released = False
        while status is None:
            if time.monotonic() > DEADLINE:
                fail("timed out")
            drain(master, 0.05)
            while transcript.count(PROBE) > answered:
                os.write(master, REPLY)
                answered += 1
            pid, st = os.waitpid(child, os.WNOHANG | os.WUNTRACED)
            if pid and os.WIFSTOPPED(st):
                drain(master, 0.1)
                stop_at = len(transcript)
                ok(lflag(master) & COOKED == COOKED, "suspend: tty cooked while stopped")
                ok(b"\x1b[<u" in transcript and b"\x1b[?1049l" in transcript[-200:],
                   "suspend: kitty pop and alt screen left before stop")
                os.killpg(child, signal.SIGCONT)
                resume_at = len(transcript)
            elif pid:
                status = st
                pgroups.discard(child)
            if resume_at is not None and not released and b"\x1b[2J" in transcript[resume_at:]:
                after = bytes(transcript[resume_at:])
                ok(lflag(master) & COOKED == 0, "resume: tty raw again")
                ok(after.find(b"\x1b[?1049h") < after.find(b"\x1b[>1u") < after.find(b"\x1b[2J")
                   and b"\x1b[?1049h" in after,
                   "resume: alt screen and kitty flags re-sent, then full repaint")
                os.write(master, b"q")
                released = True
        drain(master, 0.1)
        ok(os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0,
           f"script exit status 0 (got {status})")
        ok(stop_at is not None, "suspend: VM stopped itself")
        ok(released, "resume: input after resume reached the subscriber")
        got = dict(line.split("=", 1) for line in open(result).read().splitlines())
        ok(got.get("destructor") == "restored", f"destructor restored the tty ({got.get('destructor')})")
        ok(got.get("bad_frame") == "{:error, :bad_frame}", f"invalid row is bad_frame ({got.get('bad_frame')})")
        ok(got.get("suspend_restored") == "{:error, :restored}",
           f"suspend after restore is an error, no stop ({got.get('suspend_restored')})")
        ok(got.get("suspend") == "ok", f"suspend/resume round trip ({got.get('suspend')})")
        ok(config(master) == before, "tty settings unchanged after exit")
    if verbose:
        print("--- transcript", repr(bytes(transcript)), sep="\n")


ALT_ON, ALT_OFF, CLEAR = b"\x1b[?1049h", b"\x1b[?1049l", b"\x1b[2J"
PROMPT = b"$ "
CSI = re.compile(r"\x1b\[([0-9;?<>=]*)[ -/]*([@-~])|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b.")


def screen(data):
    """The text rows of a minimal terminal fed `data`: CUP, ED 2, CR, LF and
    printable cells only, enough to read what the demo diffed onto the screen."""
    cells, y, x = {}, 0, 0
    text = data.decode("utf-8", "replace")
    i = 0
    while i < len(text):
        m = CSI.match(text, i)
        if m:
            params, final = m.group(1), m.group(2)
            if final == "H" and params is not None:
                parts = (params.split(";") + ["", ""])[:2]
                y, x = (int(p or 1) - 1 for p in parts)
            elif final == "J" and params == "2":
                cells = {}
            i = m.end()
            continue
        ch = text[i]
        if ch == "\r":
            x = 0
        elif ch == "\n":
            y += 1
        elif ch >= " ":
            cells[(y, x)] = ch
            x += 2 if unicodedata.east_asian_width(ch) in "WF" else 1
        i += 1
    rows = {}
    for (cy, cx), ch in sorted(cells.items()):
        rows.setdefault(cy, {})[cx] = ch
    return {cy: "".join(r.get(c, " ") for c in range(max(r) + 1)) for cy, r in rows.items()}


def word(text, w):
    """`w` present as an stty -a flag (not `-w` or a longer flag)."""
    return re.search(rf"(?<![-\w]){w}(?!\w)", text) is not None


class Shell:
    """An interactive /bin/sh with job control on the master of a fresh pty."""

    def __init__(self, env):
        pid, self.fd = pty.fork()
        if pid == 0:
            try:
                os.chdir(LIVE)
                os.execve("/bin/sh", ["sh", "-i"], env)
            finally:
                os._exit(127)
        self.pid = pid
        pgroups.add(pid)  # pty.fork: the shell leads its own session and group
        self.answered = 0
        self.winsize(80, 24)

    def winsize(self, cols, rows):
        # The kernel sends SIGWINCH to the foreground process group.
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def send(self, data):
        at = len(transcript)
        os.write(self.fd, data)
        return at

    def expect(self, what, start, label):
        """Reads until `what` (bytes, or a predicate on transcript[start:])
        holds; answers kitty/DA1 probes meanwhile. Returns the transcript
        offset just past a bytes match, or the predicate's truthy result."""
        while True:
            seen = bytes(transcript[start:])
            if isinstance(what, bytes):
                at = seen.find(what)
                if at >= 0:
                    return start + at + len(what)
            else:
                got = what(seen)
                if got:
                    return got
            if time.monotonic() > DEADLINE:
                fail(f"timed out waiting for {label}")
            drain(self.fd, 0.05)
            while transcript.count(PROBE) > self.answered:
                os.write(self.fd, REPLY)
                self.answered += 1

    def paint(self, size, start, label):
        """Waits for a frame header naming `size`; returns the VM's OS pid and
        registers the wrapper job's process group for cleanup."""
        m = self.expect(lambda seen: re.search(rb"herdr-live demo " + size + rb" pid (\d+)", seen),
                        start, label)
        vm = int(m.group(1))
        try:
            pgroups.add(os.getpgid(vm))
        except OSError:
            fail(f"{label}: VM pid {vm} from the screen is not running")
        return vm

    def run(self, cmd, label):
        """Runs a shell command at the prompt; returns its output."""
        start = self.send(cmd + b"\n")
        end = self.expect(PROMPT, start + len(cmd), label)
        return bytes(transcript[start:end]).decode("utf-8", "replace")


def demo():
    with tempfile.TemporaryDirectory() as tmp:
        compile_then_start_clock(tmp)
        env = {k: v for k, v in os.environ.items()
               if k not in ("ENV", "BASH_ENV", "HERDR_SOCKET_PATH", "HERDR_CLIENT_SOCKET_PATH")}
        env.update(PS1="$ ", PS2="> ", HISTFILE="/dev/null", TERM="xterm-256color",
                   LIVE_DEMO_LOG=os.path.join(tmp, "live-demo.log"))
        sh = Shell(env)
        sh.expect(PROMPT, 0, "first prompt")
        sh.run(b"set -m", "set -m")

        start = sh.send(b"bin/live-demo\n")
        at = sh.expect(ALT_ON, start, "alt screen")
        sh.paint(b"80x24", at, "first paint")
        ok(True, "demo: alt screen entered and first frame names 80x24")

        at = sh.send(b"x")
        sh.expect(lambda seen: any("last input: 78" in r for r in screen(transcript[start:]).values()),
                  at, "last input: 78")
        ok(True, "demo: input x shown as last input: 78")

        at = sh.send(b"\x1a")
        at = sh.expect(ALT_OFF, at, "alt screen left on Ctrl-Z")
        sh.expect(PROMPT, at, "prompt after Ctrl-Z")
        ok(True, "suspend: Ctrl-Z leaves the alt screen and the shell prompts")
        out = sh.run(b"stty -a", "stty -a while suspended")
        ok(word(out, "icanon") and word(out, "echo"), "suspend: tty cooked (icanon echo) while stopped")

        at = sh.send(b"fg\n")
        at = sh.expect(CLEAR, at, "full repaint after fg")
        sh.expect(b"herdr-live demo 80x24", at, "repainted frame after fg")
        ok(lflag(sh.fd) & COOKED == 0, "resume: fg repaints fully (ESC[2J + header) and tty is raw again")

        at = len(transcript)
        sh.winsize(100, 30)
        vm = sh.paint(b"100x30", at, "resized frame")
        # Resize repaints every cell (Blit clears only after reset, not on resize).
        painted = screen(transcript[at:])
        ok(all(len(painted.get(y, "")) >= 100 for y in range(30)),
           "resize: SIGWINCH repaints all 100x30 cells")

        at = len(transcript)
        os.kill(vm, signal.SIGKILL)
        at = sh.expect(ALT_OFF, at, "wrapper restore after kill -9")
        sh.expect(PROMPT, at, "prompt after kill -9")
        ok(True, "kill -9: wrapper writes the restore sequence and the shell prompts")
        out = sh.run(b"echo demo-exit=$?", "exit status after kill -9")
        ok("demo-exit=137" in out, f"kill -9: wrapper exits with the VM's status 137 ({out!r})")
        out = sh.run(b"stty -a", "stty -a after kill -9")
        ok(word(out, "icanon") and word(out, "echo"), "kill -9: tty cooked again (icanon echo)")

        start = sh.send(b"bin/live-demo\n")
        sh.paint(b"100x30", start, "second run first paint")
        at = sh.send(b"q")
        at = sh.expect(ALT_OFF, at, "restore on q")
        sh.expect(PROMPT, at, "prompt after q")
        out = sh.run(b"echo demo-exit=$?", "exit status after q")
        ok("demo-exit=0" in out, f"quit: q exits 0 ({out!r})")
        os.write(sh.fd, b"exit\n")
    if verbose:
        print("--- transcript", repr(bytes(transcript)), sep="\n")


if __name__ == "__main__":
    modes = {"destructor": destructor, "demo": demo}
    args = [a for a in sys.argv[1:] if a != "-v"]
    if len(args) != 1 or args[0] not in modes:
        sys.exit(__doc__)
    try:
        modes[args[0]]()
    finally:
        kill_all()
