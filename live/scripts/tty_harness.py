#!/usr/bin/env python3
"""End-to-end host tty checks for HerdrTerm.Native.Tty under a real pty.

Usage: tty_harness.py destructor [-v]

destructor: runs scripts/tty_destructor.exs in the BEAM as the pty's session
leader. Answers each kitty/DA1 probe, then checks: the destructor of a killed
owner restores the tty; an invalid row is {:error, :bad_frame}; Tty.suspend
leaves the alt screen in cooked mode while the VM is stopped and, after
SIGCONT, is raw again, re-enters the alt screen, re-pushes kitty flags and
repaints fully. Prints PASS lines; exits 1 on the first failure.
"""
import fcntl
import os
import select
import signal
import subprocess
import sys
import tempfile
import termios
import time

LIVE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEADLINE = time.monotonic() + 120
PROBE = b"\x1b[?u\x1b[c"
REPLY = b"\x1b[?0u\x1b[?62c"
COOKED = termios.ICANON | termios.ECHO
verbose = "-v" in sys.argv
transcript = bytearray()
child = None


def fail(msg):
    print(f"FAIL: {msg}", file=sys.stderr)
    if verbose:
        print("--- transcript", repr(bytes(transcript)), sep="\n")
    if child:
        try:
            os.killpg(child, signal.SIGKILL)
        except OSError:
            pass
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
    global child
    with tempfile.TemporaryDirectory() as tmp:
        log = os.path.join(tmp, "compile.log")
        with open(log, "w") as out:
            built = subprocess.run(["mix", "compile"], cwd=LIVE, stdout=out, stderr=out)
        if built.returncode != 0:
            fail(f"mix compile failed: {open(log).read()[-2000:]}")
        result = os.path.join(tmp, "result")
        master, slave = os.openpty()
        before = config(master)
        child = spawn(master, slave, {**os.environ, "TTY_RESULT": result, "TTY_PATH": os.ttyname(slave)})

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
            if resume_at is not None and not released and b"\x1b[2J" in transcript[resume_at:]:
                after = bytes(transcript[resume_at:])
                ok(lflag(master) & COOKED == 0, "resume: tty raw again")
                ok(after.find(b"\x1b[?1049h") < after.find(b"\x1b[>1u") < after.find(b"\x1b[2J")
                   and b"\x1b[?1049h" in after,
                   "resume: alt screen and kitty flags re-sent, then full repaint")
                os.write(master, b"q")
                released = True
        child = None
        drain(master, 0.1)
        ok(os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0,
           f"script exit status 0 (got {status})")
        ok(stop_at is not None, "suspend: VM stopped itself")
        ok(released, "resume: input after resume reached the subscriber")
        got = dict(line.split("=", 1) for line in open(result).read().splitlines())
        ok(got.get("destructor") == "restored", f"destructor restored the tty ({got.get('destructor')})")
        ok(got.get("bad_frame") == "{:error, :bad_frame}", f"invalid row is bad_frame ({got.get('bad_frame')})")
        ok(got.get("suspend") == "ok", f"suspend/resume round trip ({got.get('suspend')})")
        ok(config(master) == before, "tty settings unchanged after exit")
    if verbose:
        print("--- transcript", repr(bytes(transcript)), sep="\n")


if __name__ == "__main__":
    modes = {"destructor": destructor}
    args = [a for a in sys.argv[1:] if a != "-v"]
    if len(args) != 1 or args[0] not in modes:
        sys.exit(__doc__)
    modes[args[0]]()
