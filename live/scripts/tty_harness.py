#!/usr/bin/env python3
"""End-to-end host tty checks for HerdrTerm.Native.Tty under a real pty.

Usage: tty_harness.py destructor|demo|herdr|herdr-stress|selfhost|persist|agent|plugins|remote|broker-kill [-v]

destructor: runs scripts/tty_destructor.exs in the BEAM as the pty's session
leader. Answers each kitty/DA1 probe, then checks: the destructor of a killed
owner restores the tty; an invalid row is {:error, :bad_frame}; Tty.suspend
leaves the alt screen in cooked mode while the VM is stopped and, after
SIGCONT, is raw again, re-enters the alt screen, re-pushes kitty flags and
repaints fully.

demo: drives bin/live-demo as a job of an interactive /bin/sh (job control on)
in a pty: first paint, input, Ctrl-Z / fg with full repaint, SIGWINCH resize,
kill -9 of the VM (the wrapper restores the tty), `kill %1` of a suspended job
(it runs on in the background without touching the tty, never stopped by
SIGTTOU/SIGTTIN, and exits non-zero), `kill %1; fg` (ends on the main screen,
cooked), and `q` exiting 0.

herdr: runs bin/herdr-live attached (real tty and blit kernels, real server
kernel) as the session leader of a 120x40 pty: first frame (alt screen,
TERMINAL status), prefix v and prefix - split (three shell prompts), typing
`echo hi-from""-pty` shows the shell's output, a resize to 100x30 repaints
(SIGWINCH), prefix q (detach) quits with
status 0, the restore sequence (kitty pop, alt screen left) and unchanged
tty settings.

herdr-stress: the same launch, then grows to 15 panes (each time clicking the
largest pane with an SGR mouse press, then prefix v or -), cats a 21 MB file
in a loop in one pane while typing in another, checks the typed echo shows up
while the loop still runs (it stops only after that) and reports its latency,
then quits.

selfhost: the self-hosting loop through the real launcher. The same launch
(120x40), prefix v, then writes a new module file
apps/herdr_server/lib/herdr_server/selfhost_probe.ex and waits for the
status row to show `r<n> 1m` (rewritten every 2 s until a batch shows, as a
defense: since b30f3505 the status bridge subscribes at once and seeds from
the newest batch, so the first write normally shows); `bin/herdr-live rollback` shows
`r<n> rolled back: manual`; `bin/herdr-live kernel-restart` shows
`handoff graceful g<gen>` and both panes still answer an `echo` (clicked to
focus), and a pane shell has HERDR_BROKER_SOCK set; the probe file is deleted (the status settles), prefix q exits 0, and
log_summary.py on the run's log reports reloads >= 1, rollbacks manual 1,
handoffs graceful 1, session_losses 0. The probe file is removed in a
`finally` (also on Ctrl-C); afterwards no probe beam is left in
_build/dev/lib/herdr_server/ebin and `git status --porcelain -- live/apps`
equals its value at the start.

persist: M8's exit criterion (stop, start, identical layout and cwds). Run 1
(120x40): prefix v, in the new pane `cd <tmp>/dir-b; echo m8-marker-b`, prefix c
(new tab) and `cd <tmp>/dir-c`, prefix p back to tab 1, 3 s, prefix q (exit 0);
persist_dump.exs on <tmp>/state/session.default.etf is dump A (it must record both
cwds, two tabs, a side-by-side split). Run 2 on the same state dir: the log has
`persist_restore source=disk reason=boot`, the screen shows m8-marker-b (scrollback
replay), the focused pane's `pwd` is dir-b; 3 s, prefix q, dump B. PASS when A == B.

agent: an agent in a pane drives herdr-live through the CLI. The same launch
(120x40); the first pane's shell runs "$HERDR_LIVE_BIN" (exported by the
launcher, as is HERDR_LIVE_API) with output into the run's temp dir: pane split
--direction right (split.json has pane.pane_id, two prompts), pane run <id>
'echo agent-""marker', pane wait-output <id> --match agent-marker, pane read
<id> (contains agent-marker), pane list (2 panes, the caller's HERDR_PANE_ID
among them), agent list (stderr has code not_available) and 10 timed pings
(mean latency printed). Prefix q exits 0 and log_summary.py reports api
connects >= 5 and session_losses 0.

plugins: M14's exit criterion, two of herdr's example plugins
(vendor/herdr-plugin-examples, unmodified) end to end. The same launch with its own
XDG_CONFIG_HOME and XDG_STATE_HOME (plugin registry, checkouts, config and state dirs
under the temp dir) and a temp bin/ first on PATH with two stubs, so the plugins run
unmodified and offline: `gh` prints `stub-gh <args>` (github-link-preview's preview.sh
calls gh) and `nvim` prints stub-nvim (dev-layout-bootstrap runs `nvim .` in the first
pane). `lua` must be on PATH (setup.lua): the mode fails without it, never skips. From the
first pane's shell: plugin install of both (--yes), both listed enabled without error;
plugin action invoke examples.dev-layout-bootstrap.setup succeeds (plugin log list) with
three panes labelled editor, files, tasks, `ready.` in files and stub-nvim in the editor;
an OSC 8 link to a GitHub issue printed in the editor, ctrl+clicked through the pty (SGR
press with the ctrl bit) opens a pane labelled `GitHub preview` showing `github issues #1`
and the stub gh output; pane link activate --modifier ctrl over the API does the same;
plugin link of a manifest without version fails with invalid_plugin_version; a linked
plugin whose manifest is then corrupted lists with its error, cannot run, the examples
still list clean and run, and the log has its `plugin:` warning line; plugin disable makes
invoke fail with plugin_disabled, enable, uninstall drops it from plugin list; prefix q
exits 0 and log_summary.py reports session_losses 0.

remote: M16's remote attach. A (120x40) runs the instance; B (80x24) runs
`bin/herdr-live attach fakehost` with HERDR_LIVE_SSH=bench/remote/fake_ssh.sh (the
relay runs locally) and its own transcript: B shows TERMINAL on row 24, an echo
typed in either shows in the other; killing the relay (its pid file) shows
reconnecting in B, then a client_reconnect and B's echo on A; kernel-restart
carries B's socket (client_held carried=true, no client_reconnect for B) and B's
echo still reaches A; prefix q ends only B (exit 0, tty restored), A answers, A
quits; log_summary.py reports clients attaches >= 2 and session_losses 0. On a
failure the client and server log tails are printed.

broker-kill: the same launch (120x40), then kill -9 of the broker (its pid from
`bin/herdr-live status`): tty_guard.sh restores the tty (settings unchanged, mouse
off, alt screen left), the launcher exits 137 and the log has broker_killed. A
second launch gets SIGTERM on the launcher pid: the guard forwards TERM to the
broker, a clean stop (exit 0, settings unchanged, no broker_killed).

herdr, herdr-stress, selfhost, persist, agent, plugins, remote and broker-kill launch bin/herdr-live and compile into the
shared _build/dev, so they skip (print SKIP, exit 0) inside a herdr-live pane:
pane shells inherit the VM's HERDR_BROKER_SOCK. Run them outside the dogfood
instance (another terminal or worktree).

Every herdr-live launch gets its own HERDR_LIVE_LOG, HERDR_LIVE_API,
HERDR_LIVE_RUNTIME_DIR, HERDR_LIVE_STATE_DIR and HERDR_LIVE_CONFIG (a config with
`onboarding = false`, so no welcome modal) under the run's temp dir, so the
CLI calls address that instance only and no run reads or writes the human's
session file.

Prints PASS lines; exits 1 on the first failure. Every mode SIGKILLs the
process groups it started on any exit, including Ctrl-C. The 120 s deadline
starts after `mix compile` (itself capped at COMPILE_TIMEOUT seconds).
"""
import fcntl
import json
import os
import pty
import re
import struct
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import termios
import time
import unicodedata

LIVE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUN_SECONDS = 120
# remote mode: outlasts the client's longest reconnect/resync backoff (the max of `backoff`
# in apps/herdr_term/lib/herdr_term/remote/conn.ex, 5 s) plus slack; keep above it
REMOTE_BACKOFF_WINDOW = 6
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
            # Launched like bin/herdr-live, so the BEAM never drives the tty itself.
            os.execvpe("elixir", ["elixir", "--erl", "-noshell -noinput", "-S", "mix", "run",
                                  "--no-start", "scripts/tty_destructor.exs"], env)
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
                # One suspend is exactly one stop; a second means the resumed VM stopped again.
                if stop_at is not None:
                    fail("suspend: VM stopped a second time after SIGCONT")
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


class Screen:
    """An incremental `screen()`: feed() output chunks (escape sequences and
    UTF-8 may be split across chunks), rows() for the current text rows."""

    SEQ = re.compile(r"\x1b\[([0-9;:?<>=]*)[ -/]*([@-~])|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")
    PARTIAL = re.compile(r"\x1b(?:\[[0-9;:?<>=]*[ -/]*|\][^\x07\x1b]*\x1b?)?")

    def __init__(self):
        import codecs
        self.utf8 = codecs.getincrementaldecoder("utf-8")("replace")
        self.pending = ""
        self.cells, self.y, self.x = {}, 0, 0

    def feed(self, data):
        text = self.pending + self.utf8.decode(bytes(data))
        self.pending = ""
        i, n = 0, len(text)
        while i < n:
            ch = text[i]
            if ch == "\x1b":
                m = self.SEQ.match(text, i)
                if m:
                    if m.group(2) == "H":
                        parts = (m.group(1).split(";") + ["", ""])[:2]
                        self.y, self.x = (int(p or 1) - 1 for p in parts)
                    elif m.group(2) == "J" and m.group(1) == "2":
                        self.cells = {}
                    i = m.end()
                elif self.PARTIAL.fullmatch(text, i):
                    self.pending = text[i:]
                    return
                else:
                    i += 2
                continue
            if ch == "\r":
                self.x = 0
            elif ch == "\n":
                self.y += 1
            elif ch >= " ":
                self.cells[(self.y, self.x)] = ch
                self.x += 2 if unicodedata.east_asian_width(ch) in "WF" else 1
            i += 1

    def rows(self):
        rows = {}
        for (cy, cx), ch in self.cells.items():
            rows.setdefault(cy, {})[cx] = ch
        return ["".join(rows.get(y, {}).get(c, " ") for c in range(max(rows.get(y, {0: 0})) + 1))
                for y in range(max(rows, default=-1) + 1)]

    def text(self):
        return "\n".join(self.rows())


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
            self.job = os.getpgid(vm)
        except OSError:
            fail(f"{label}: VM pid {vm} from the screen is not running")
        pgroups.add(self.job)
        return vm

    def ended(self, at, what, restore=True):
        """After the demo job ends: the restore sequence and a prompt follow,
        and the tty is cooked again. Returns the job's exit status. Without
        `restore`, a job that ends before it re-enters the alt screen may
        write nothing; the screen must still end on the main screen."""
        if restore:
            at = self.expect(ALT_OFF, at, f"restore after {what}")
            self.expect(PROMPT, at, f"prompt after {what}")
        else:
            def settled(seen):
                if seen.rfind(ALT_ON) > seen.rfind(ALT_OFF):
                    return False
                return seen.find(PROMPT, max(seen.rfind(ALT_OFF), 0)) >= 0
            self.expect(settled, at, f"prompt on the main screen after {what}")
        pgroups.discard(self.job)
        ok(self.main_screen(at) and lflag(self.fd) & COOKED == COOKED,
           f"{what}: {'restore sequence, ' if restore else ''}prompt, main screen, tty cooked")
        out = self.run(b"echo demo-exit=$?", f"exit status after {what}")
        m = re.search(r"demo-exit=(\d+)", out)
        if not m:
            fail(f"{what}: no exit status in {out!r}")
        return int(m.group(1))

    def suspend(self):
        """Ctrl-Z: the alt screen is left and the shell prompts."""
        at = self.send(b"\x1a")
        self.expect(PROMPT, self.expect(ALT_OFF, at, "alt screen left on Ctrl-Z"), "prompt after Ctrl-Z")

    def main_screen(self, at):
        """No alt screen entered since `at` is still open."""
        seen = bytes(transcript[at:])
        return seen.rfind(ALT_ON) <= seen.rfind(ALT_OFF)

    def run(self, cmd, label):
        """Runs a shell command at the prompt; returns its output."""
        start = self.send(cmd + b"\n")
        end = self.expect(PROMPT, start + len(cmd), label)
        return bytes(transcript[start:end]).decode("utf-8", "replace")


def alive_group(pgid):
    """A process of group `pgid` still runs (zombies do not count: dash reaps
    a background job only when it next runs a command)."""
    out = subprocess.run(["ps", "-A", "-o", "pgid=,stat="], capture_output=True, text=True).stdout
    return any(f[0] == str(pgid) and not f[1].startswith("Z")
               for f in (line.split() for line in out.splitlines()) if len(f) == 2)


def demo():
    with tempfile.TemporaryDirectory() as tmp:
        compile_then_start_clock(tmp)
        env = {k: v for k, v in os.environ.items()
               if k not in ("ENV", "BASH_ENV", "HERDR_SOCKET_PATH", "HERDR_CLIENT_SOCKET_PATH")}
        env.update(PS1="$ ", PS2="> ", HISTFILE="/dev/null", TERM="xterm-256color",
                   LIVE_DEMO_LOG=os.path.join(tmp, "live-demo.log"))
        log = env["LIVE_DEMO_LOG"]
        sh = Shell(env)
        sh.expect(PROMPT, 0, "first prompt")
        # Job control on; no line editor, so the tty stays cooked at the prompt.
        sh.run(b"set -m; set +o emacs 2>/dev/null; set +o vi 2>/dev/null", "shell setup")

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
        sh.expect(lambda _: all(len(screen(transcript[at:]).get(y, "")) >= 100 for y in range(30)),
                  at, "full 100x30 repaint")
        ok(True, "resize: SIGWINCH repaints all 100x30 cells")

        at = len(transcript)
        os.kill(vm, signal.SIGKILL)
        status = sh.ended(at, "kill -9")
        ok(status == 137, f"kill -9: wrapper exits with the VM's status 137 (got {status})")
        out = sh.run(b"stty -a", "stty -a after kill -9")
        ok(word(out, "icanon") and word(out, "echo"), "kill -9: stty -a shows icanon echo")

        # A signal to the stopped job reaches the wrapper sh too. bash's `kill %1` also
        # sends SIGCONT (dash's does not, hence the explicit one), so the job runs on
        # in the background, where the VM must not touch the tty: a tcsetattr or read
        # there raises SIGTTOU/SIGTTIN, which can land after a later `fg` and stop the
        # job again (the old `kill %1; fg` flake).
        start = sh.send(b"bin/live-demo\n")
        vm = sh.paint(b"100x30", start, "second run first paint")
        sh.suspend()
        at = len(transcript)
        sh.run(b"kill %1; kill -CONT %1", "prompt after kill %1")

        def stopped():
            return "T" in subprocess.run(["ps", "-o", "stat=", "-p", str(vm)],
                                         capture_output=True, text=True).stdout

        # The VM logs SIGTERM once it runs again; a tty access stops it first.
        got = sh.expect(lambda _: ("stopped" if stopped() else
                                   "SIGTERM received" in open(log).read() and "running"),
                        at, "VM resumed in the background")
        if got == "running":
            time.sleep(0.5)
            got = "stopped" if stopped() else got
        ok(got == "running", f"kill %1: the VM runs on in the background, not stopped by tty access ({got})")
        # It exits there; the guard leaves the shell's tty alone (suspend restored it).
        sh.expect(lambda _: not alive_group(sh.job), at, "background job exit after kill %1")
        pgroups.discard(sh.job)
        out = sh.run(b"jobs", "jobs after kill %1")
        m = re.search(r"(?:Exit |Done\()(\d+)", bytes(transcript[at:]).decode("utf-8", "replace"))
        ok(m is not None and m.group(1) != "0", f"kill %1: background job exits non-zero ({out!r})")
        ok(ALT_ON not in transcript[at:] and lflag(sh.fd) & COOKED == COOKED,
           "kill %1: tty cooked, alt screen never re-entered from the background")

        # `kill %1; fg`: the VM resumes in the background and is foregrounded at once.
        start = sh.send(b"bin/live-demo\n")
        sh.paint(b"100x30", start, "third run first paint")
        sh.suspend()
        status = sh.ended(sh.send(b"kill %1; fg\n"), "kill %1; fg", restore=False)
        ok(status != 0, f"kill %1; fg: wrapper exits non-zero (got {status})")

        start = sh.send(b"bin/live-demo\n")
        sh.paint(b"100x30", start, "fourth run first paint")
        status = sh.ended(sh.send(b"q"), "q")
        ok(status == 0, f"quit: q exits 0 (got {status})")
        os.write(sh.fd, b"exit\n")
    if verbose:
        print("--- transcript", repr(bytes(transcript)), sep="\n")


class Herdr:
    """bin/herdr-live attached, leading the session of a fresh cols x rows pty."""

    # the open terminals: until() and cli() pump them all, so a second pty (remote)
    # never fills up while the checks wait on the other
    running = []

    def __init__(self, tmp, cols, rows, run="", args=(), extra_env=None):
        """`run` names the log, API socket and runtime dir, so two launches in one
        temp dir (persist) stay apart; the state dir (session files) is the temp dir's.
        `args` launches `bin/herdr-live args` (attach: a client of the instance named by
        `run`) with its own transcript; the plain launch uses the global one."""
        self.args = tuple(args)
        self.transcript = bytearray() if args else transcript
        self.log = os.path.join(tmp, f"herdr-live{run}.log")
        self.tmp = tmp
        self.master, slave = os.openpty()
        fcntl.ioctl(self.master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.before = config(self.master)
        self.screen = Screen()
        self.answered = 0
        env = {k: v for k, v in os.environ.items()
               if k not in ("ENV", "BASH_ENV", "HERDR_SOCKET_PATH", "HERDR_CLIENT_SOCKET_PATH",
                            "HERDR_LIVE_HEADLESS", "HERDR_LIVE_TEST_ON_SAVE", "HERDR_BROKER_SOCK",
                            "HERDR_LIVE_SESSION", "HERDR_LIVE_PERSIST", "HERDR_PANE_ID", "HERDR_LIVE_BIN")}
        # the panes' shell: plain sh with a known prompt; sockets and session files of
        # this instance only (never the human's session.default.etf)
        self.state = os.path.join(tmp, "state")
        # the config file (M13): this run's, without the first-run welcome; a second
        # launch in the same temp dir (persist) keeps whatever the first wrote
        config_path = os.path.join(tmp, "config.toml")
        if not os.path.exists(config_path):
            with open(config_path, "w") as f:
                f.write("onboarding = false\n")
        env.update(SHELL="/bin/sh", PS1="$ ", HISTFILE="/dev/null", TERM="xterm-256color",
                   HERDR_LIVE_LOG=self.log, HERDR_LIVE_API=os.path.join(tmp, f"api{run}.sock"),
                   HERDR_LIVE_RUNTIME_DIR=os.path.join(tmp, f"rt{run}"), HERDR_LIVE_STATE_DIR=self.state,
                   HERDR_LIVE_CONFIG=config_path)
        env.update(extra_env or {})
        self.env = env
        pid = os.fork()
        if pid == 0:
            try:
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
                os.dup2(slave, 0)
                os.dup2(slave, 1)
                os.dup2(slave, 2)
                os.close(self.master)
                os.execve(os.path.join(LIVE, "bin", "herdr-live"), ["herdr-live", *self.args], env)
            finally:
                os._exit(127)
        os.close(slave)
        self.pid = pid
        pgroups.add(pid)
        Herdr.running.append(self)

    def pump(self, wait=0.05):
        """Reads for at most `wait` seconds (a busy stream never starves the checks)."""
        transcript = self.transcript
        at, end = len(transcript), time.monotonic() + wait
        while (left := end - time.monotonic()) > 0 and select.select([self.master], [], [], left)[0]:
            try:
                data = os.read(self.master, 65536)
            except OSError:
                break
            if not data:
                break
            transcript.extend(data)
        self.screen.feed(transcript[at:])
        while transcript.count(PROBE) > self.answered:
            os.write(self.master, REPLY)
            self.answered += 1

    def until(self, check, label, timeout=None):
        end = min(DEADLINE, time.monotonic() + timeout) if timeout else DEADLINE
        while True:
            got = check()
            if got:
                return got
            if time.monotonic() > end:
                if verbose:
                    print("--- screen", self.screen.text(), sep="\n")
                fail(f"timed out waiting for {label}")
            pump_all()

    def send(self, data):
        os.write(self.master, data)

    def prompts(self):
        return sum(len(re.findall(r"\$ ", row)) for row in self.screen.rows())

    def shows(self, text):
        return text in self.screen.text()

    def cli(self, *args, timeout=60):
        """Runs `bin/herdr-live args` against this instance, pumping the pty meanwhile;
        returns (exit status, output)."""
        out = os.path.join(self.tmp, "cli.out")
        with open(out, "w") as f:
            p = subprocess.Popen([os.path.join(LIVE, "bin", "herdr-live"), *args], cwd=LIVE,
                                 env=self.env, stdin=subprocess.DEVNULL, stdout=f, stderr=f,
                                 start_new_session=True)
        pgroups.add(p.pid)
        try:
            end = min(DEADLINE, time.monotonic() + timeout)
            while p.poll() is None:
                if time.monotonic() > end:
                    fail(f"herdr-live {' '.join(args)} timed out")
                pump_all()
        finally:
            if p.poll() is None:
                os.killpg(p.pid, signal.SIGKILL)
                p.wait()
            pgroups.discard(p.pid)
        with open(out) as f:
            return p.returncode, f.read()

    def click(self, x, y):
        at = f"{x + 1};{y + 1}".encode()
        self.send(b"\x1b[<0;" + at + b"M\x1b[<0;" + at + b"m")

    def start(self):
        self.until(lambda: os.path.exists(self.log) and "terminal client started" in open(self.log).read(),
                   "terminal client started")
        self.until(lambda: ALT_ON in self.transcript and self.shows("TERMINAL") and self.prompts() >= 1,
                   "first frame with TERMINAL and a prompt")
        ok(True, "herdr: alt screen, first frame with TERMINAL status and the pane's prompt")

    def quit(self):
        transcript = self.transcript
        at = len(transcript)
        self.send(b"\x02q")
        status = None
        while status is None:
            if time.monotonic() > DEADLINE:
                fail("timed out waiting for herdr-live to exit after prefix q")
            self.pump()
            pid, st = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                status = st
        pgroups.discard(self.pid)
        Herdr.running.remove(self)
        self.pump(0.1)
        after = bytes(transcript[at:])
        ok(os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0,
           f"quit: prefix q (detach) exits 0 (got {status})")
        ok(b"\x1b[<u" in after and after.rfind(ALT_OFF) > after.rfind(b"\x1b[<u"),
           "quit: kitty flags popped, then the alt screen left")
        ok(config(self.master) == self.before, "quit: tty settings unchanged")
        if not self.args:
            log = open(self.log).read()
            ok("herdr-live stopped" in log, "quit: log has herdr-live stopped")


def pump_all():
    for h in Herdr.running:
        h.pump()


def herdr():
    with tempfile.TemporaryDirectory() as tmp:
        compile_then_start_clock(tmp)
        h = Herdr(tmp, 120, 40)
        h.start()
        h.send(b"\x02v")
        h.until(lambda: h.prompts() >= 2, "second prompt after prefix v")
        h.send(b"\x02-")
        h.until(lambda: h.prompts() >= 3, "third prompt after prefix -")
        ok(True, "herdr: prefix v and prefix - split (three prompts)")
        h.send(b'echo hi-from""-pty\r')
        h.until(lambda: h.shows("hi-from-pty"), "the shell's echo output")
        ok(b"hi-from-pty" in transcript, "herdr: typed echo ran in the focused pane (hi-from-pty)")
        fcntl.ioctl(h.master, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        h.until(lambda: len(h.screen.rows()) >= 30 and h.screen.rows()[29].startswith("TERMINAL"),
                "status row on row 30 after the resize")
        ok(True, "herdr: SIGWINCH to 100x30 moves the status row to row 30")
        h.quit()
    if verbose:
        print("--- screen", h.screen.text(), sep="\n")


def wait_exit(h, label):
    """Pumps the pty until the launcher pid exits; returns its wait status."""
    while True:
        if time.monotonic() > DEADLINE:
            fail(f"timed out waiting for herdr-live to exit after {label}")
        h.pump()
        pid, st = os.waitpid(h.pid, os.WNOHANG)
        if pid:
            pgroups.discard(h.pid)
            h.pump(0.1)
            # a later pump_all must not answer probes on this dead pty (EIO)
            Herdr.running.remove(h)
            return st


def describe_status(st):
    if os.WIFEXITED(st):
        return f"exit {os.WEXITSTATUS(st)}"
    return f"signal {os.WTERMSIG(st)}" if os.WIFSIGNALED(st) else f"status {st}"


def broker_kill():
    with tempfile.TemporaryDirectory() as tmp:
        compile_then_start_clock(tmp)
        h = Herdr(tmp, 120, 40)
        h.start()
        rc, out = h.cli("status")
        m = re.search(r"^broker_pid=(\d+)$", out, re.M)
        ok(rc == 0 and m, f"broker-kill: status prints broker_pid ({out!r})")
        at = len(transcript)
        os.kill(int(m.group(1)), signal.SIGKILL)
        st = wait_exit(h, "kill -9 of the broker")
        tail = bytes(transcript[at:])
        ok(os.WIFEXITED(st) and os.WEXITSTATUS(st) == 137,
           f"broker-kill: the launcher exits with the broker's status 137 (got {describe_status(st)})")
        ok(config(h.master) == h.before, "broker-kill: tty settings unchanged after kill -9 of the broker")
        ok(ALT_OFF in tail and b"\x1b[?1000l" in tail,
           "broker-kill: restore sequence written (mouse off, alt screen left)")
        ok("broker_killed" in open(h.log).read(), "broker-kill: log has broker_killed")
        # SIGTERM to the launcher reaches the broker as TERM through the guard: a clean stop
        h2 = Herdr(tmp, 120, 40, run="-term")
        h2.start()
        os.kill(h2.pid, signal.SIGTERM)
        st = wait_exit(h2, "SIGTERM")
        ok(os.WIFEXITED(st) and os.WEXITSTATUS(st) == 0,
           f"broker-kill: SIGTERM to the launcher exits 0 (got {describe_status(st)})")
        ok(config(h2.master) == h2.before, "broker-kill: tty settings unchanged after SIGTERM")
        ok("broker_killed" not in open(h2.log).read(), "broker-kill: no broker_killed after SIGTERM")


def herdr_stress():
    global DEADLINE
    with tempfile.TemporaryDirectory() as tmp:
        compile_then_start_clock(tmp)
        DEADLINE += 120
        big = os.path.join(tmp, "big.txt")
        with open(big, "w") as f:
            for n in range(1, 300_001):
                f.write(f"{n:08d} " + "x" * 60 + "\n")
        size = os.path.getsize(big)
        cols, rows = 120, 40
        h = Herdr(tmp, cols, rows)
        h.start()
        # model of the pane rects (right of the 26-col sidebar, under the tab bar, above the
        # status row); only the centres are used
        panes = [(26.0, 1.0, float(cols - 26), float(rows - 2))]
        while len(panes) < 15:
            x, y, w, hh = max(panes, key=lambda r: r[2] * r[3])
            panes.remove((x, y, w, hh))
            h.click(int(x + w / 2), int(y + hh / 2))
            if w > 2 * hh:
                h.send(b"\x02v")
                panes += [(x, y, w / 2, hh), (x + w / 2, y, w / 2, hh)]
            else:
                h.send(b"\x02-")
                panes += [(x, y, w, hh / 2), (x, y + hh / 2, w, hh / 2)]
            want = len(panes)
            h.until(lambda: h.prompts() >= want, f"{want} prompts", timeout=10)
        ok(h.prompts() == 15, f"stress: 15 panes by click + split (prompts {h.prompts()})")
        cat_pane, typed_pane = panes[0], panes[-1]
        cx, cy, cw, ch = cat_pane
        h.click(int(cx + cw / 2), int(cy + ch / 2))
        # the cat repeats until the harness creates `stop`, which it does only after
        # the typed echo showed: the echo is structurally during the cat
        stop = os.path.join(tmp, "stop")
        h.send(f'while [ ! -e {stop} ]; do cat {big}; done; echo END""-CAT\r'.encode())
        h.until(lambda: re.search(r"\d{8} x", h.screen.text()), "cat output on screen", timeout=20)
        tx, ty, tw, th = typed_pane
        h.click(int(tx + tw / 2), int(ty + th / 2))
        t0 = time.monotonic()
        h.send(b'echo typed""-ok\r')
        h.until(lambda: h.shows("typed-ok"), "typed echo during the cat", timeout=30)
        latency = time.monotonic() - t0
        ok(not h.shows("END-CAT"), f"stress: typed echo shown during the cat, {latency * 1000:.0f} ms after the keys")
        open(stop, "w").close()
        h.until(lambda: h.shows("END-CAT"), "end of the cat", timeout=120)
        ok(True, f"stress: the {size / 1e6:.1f} MB cat loop ended once told to")
        h.until(lambda: re.search(r"00300000 x", h.screen.text()), "last cat line", timeout=10)
        ok(True, "stress: the cat pane shows its last line")
        h.quit()
    if verbose:
        print("--- screen", h.screen.text(), sep="\n")


PROBE_SRC = os.path.join(LIVE, "apps", "herdr_server", "lib", "herdr_server", "selfhost_probe.ex")
PROBE_BEAM = os.path.join(LIVE, "_build", "dev", "lib", "herdr_server", "ebin",
                          "Elixir.HerdrServer.SelfhostProbe.beam")


def settle(h, quiet=3.0, timeout=30):
    """Pumps until the log has not grown for `quiet` seconds."""
    end = time.monotonic() + timeout
    size, since = -1, time.monotonic()
    while time.monotonic() < end:
        now = os.path.getsize(h.log)
        if now != size:
            size, since = now, time.monotonic()
        elif time.monotonic() - since >= quiet:
            return
        h.pump(0.1)
    fail("the log did not settle after deleting the probe")


def write_probe(n):
    """Writes the probe atomically: the watcher ignores the .tmp name, then sees one .ex event."""
    tmp = PROBE_SRC + ".tmp"
    with open(tmp, "w") as f:
        f.write(f"defmodule HerdrServer.SelfhostProbe, do: def(v, do: {n})\n")
    os.replace(tmp, PROBE_SRC)


def git_apps():
    return subprocess.run(["git", "status", "--porcelain", "--", "apps"], cwd=LIVE,
                          capture_output=True, text=True, check=True).stdout


def selfhost():
    global DEADLINE
    if os.path.exists(PROBE_SRC):
        fail(f"{PROBE_SRC} already exists (left by an interrupted run?): delete it, then rerun")
    before = git_apps()
    with tempfile.TemporaryDirectory() as tmp:
        compile_then_start_clock(tmp)
        DEADLINE += 120
        cols, rows = 120, 40
        h = Herdr(tmp, cols, rows)
        try:
            h.start()
            h.send(b"\x02v")
            h.until(lambda: h.prompts() >= 2, "second prompt after prefix v")
            ok(True, "selfhost: prefix v split (two prompts)")
            # ReloadNotices (the status line's bridge) subscribes right after the reload
            # pipeline starts and seeds from the newest batch (b30f3505), so the first write
            # normally shows; rewriting the probe (new value) every 2 s stays as a defense
            h.until(lambda: "herdr-event vm_start" in read_text(h.log), "vm_start in the log")
            n = int(time.time() * 1000) % 1_000_000_000
            loaded = lambda: re.search(r"\br(\d+) 1m\b", h.screen.text())
            writes = 0
            while not loaded():
                if writes >= 30 or time.monotonic() > DEADLINE:
                    fail(f"no r<n> 1m after {writes} probe writes")
                write_probe(n + writes)
                writes += 1
                end = time.monotonic() + 2
                while not loaded() and time.monotonic() < end:
                    h.pump()
            # a rewrite that crossed the first load makes one more batch: take the newest
            settle(h, quiet=1.5)
            batch = int(h.until(loaded, "r<n> 1m after the log settled", timeout=5).group(1))
            ok(True, f"selfhost: new module file reloads, status shows r{batch} 1m ({writes} write(s))")
            code, out = h.cli("rollback")
            ok(code == 0, f"selfhost: herdr-live rollback exits 0 ({out.strip()})")
            h.until(lambda: h.shows(f"r{batch} rolled back: manual"), f"r{batch} rolled back: manual",
                    timeout=20)
            ok(True, f"selfhost: status shows r{batch} rolled back: manual")
            code, out = h.cli("kernel-restart", timeout=90)
            ok(code == 0, f"selfhost: herdr-live kernel-restart exits 0 ({out.strip()})")
            m = h.until(lambda: re.search(r"handoff graceful g\d+", h.screen.text()),
                        "handoff graceful g<gen>", timeout=60)
            ok(True, f"selfhost: status shows {m.group(0)}")
            for i, x in enumerate((cols // 4, 3 * cols // 4)):
                h.click(x, (rows - 1) // 2)
                mark = f"alive{i}-{n}"
                h.send(f'echo {mark[:5]}""{mark[5:]}\r'.encode())
                h.until(lambda: h.shows(mark), f"echo {mark} after the handoff", timeout=20)
                ok(True, f"selfhost: pane {i + 1} answers an echo after the handoff ({mark})")
            # the marker the launcher modes skip on: pane shells inherit the VM's broker socket
            h.send(b'echo inside-${HERDR_BROKER_SOCK:+herdr}-live\r')
            h.until(lambda: h.shows("inside-herdr-live"), "HERDR_BROKER_SOCK in a pane's env", timeout=20)
            ok(True, "selfhost: a pane shell has HERDR_BROKER_SOCK (the harness skip marker)")
            os.remove(PROBE_SRC)
            settle(h)
            last = h.screen.rows()[rows - 1].strip() if len(h.screen.rows()) >= rows else ""
            ok(True, f"selfhost: probe deleted, status settled ({last!r})")
            h.quit()
        finally:
            for f in (PROBE_SRC, PROBE_SRC + ".tmp"):
                if os.path.exists(f):
                    os.remove(f)
        summary = subprocess.run([sys.executable, os.path.join(LIVE, "scripts", "log_summary.py"), h.log],
                                 capture_output=True, text=True)
        print(summary.stdout, end="")
        if verbose:
            with open(h.log) as f:
                print("--- reload events", *[l.rstrip() for l in f if re.search(r"herdr-event (reload|rollback)", l)],
                      sep="\n")

        s = json.loads(subprocess.run([sys.executable, os.path.join(LIVE, "scripts", "log_summary.py"),
                                       h.log, "--json"], capture_output=True, text=True, check=True).stdout)
        ok(s["reloads"] >= 1, f"selfhost: log summary reloads >= 1 ({s['reloads']})")
        ok(s["rollbacks"]["manual"] == 1, f"selfhost: log summary rollbacks manual 1 ({s['rollbacks']})")
        ok(s["handoffs"]["graceful"] == 1, f"selfhost: log summary handoffs graceful 1 ({s['handoffs']})")
        ok(s["session_losses"] == 0, f"selfhost: log summary session_losses 0 ({s['session_losses']})")
    ok(not os.path.exists(PROBE_BEAM), "selfhost: no probe beam left in _build/dev/lib/herdr_server/ebin")
    after = git_apps()
    ok(after == before and not os.path.exists(PROBE_SRC),
       f"selfhost: the harness must leave live/apps as it found it (git status before {before.strip()!r},"
       f" after {after.strip()!r})")
    if verbose:
        print("--- screen", h.screen.text(), sep="\n")


def read_text(path):
    with open(path) as f:
        return f.read()


def persist_dump(path):
    """(saved_at ms, persist_dump.exs lines without saved_at) for a session file; fails on
    a missing or bad file."""
    if not os.path.exists(path):
        fail(f"no session file {path}")
    r = subprocess.run(["elixir", os.path.join(LIVE, "scripts", "persist_dump.exs"), path],
                       capture_output=True, text=True, timeout=180)
    if r.returncode != 0:
        fail(f"persist_dump.exs {path} exited {r.returncode}: {r.stderr.strip()}")
    first, _, rest = r.stdout.partition("\n")
    if not first.startswith("saved_at="):
        fail(f"persist_dump.exs: no saved_at line first ({first!r})")
    return int(first[len("saved_at="):]), rest


def log_json(log):
    return json.loads(subprocess.run([sys.executable, os.path.join(LIVE, "scripts", "log_summary.py"),
                                      log, "--json"], capture_output=True, text=True, check=True).stdout)


def persist():
    global DEADLINE
    # under /tmp: a short realpath keeps the cwds on one row and the sockets short
    with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
        tmp = os.path.realpath(tmp)
        compile_then_start_clock(tmp)
        DEADLINE += 240
        dir_b, dir_c = os.path.join(tmp, "dir-b"), os.path.join(tmp, "dir-c")
        os.makedirs(dir_b)
        os.makedirs(dir_c)
        cols, rows = 120, 40
        h = Herdr(tmp, cols, rows, run=".1")
        h.start()
        h.send(b"\x02v")
        h.until(lambda: h.prompts() >= 2, "second prompt after prefix v")
        h.send(f'cd {dir_b}; echo m8-""marker-b\r'.encode())
        h.until(lambda: h.shows("m8-marker-b"), "m8-marker-b in the new pane", timeout=30)
        ok(True, "persist run 1: prefix v split, the new pane cd'd to dir-b and echoed m8-marker-b")
        h.send(b"\x02c")
        # m13: prefix c opens a name prompt; enter accepts the default name
        h.until(lambda: h.shows("new tab") and h.shows("save"), "new tab name prompt", timeout=30)
        h.send(b"\r")
        h.until(lambda: not h.shows("m8-marker-b") and h.prompts() >= 1, "new tab after prefix c",
                timeout=30)
        h.send(f'cd {dir_c}; echo in-""dir-c\r'.encode())
        h.until(lambda: h.shows("in-dir-c"), "in-dir-c in the new tab", timeout=30)
        ok(True, "persist run 1: prefix c new tab, its pane cd'd to dir-c")
        h.send(b"\x02p")
        h.until(lambda: h.shows("m8-marker-b") and h.prompts() >= 2, "tab 1 again after prefix p",
                timeout=30)
        ok(True, "persist run 1: prefix p back to tab 1 (two panes, m8-marker-b)")
        end = time.monotonic() + 3
        while time.monotonic() < end:
            h.pump(0.1)
        h.quit()
        session = os.path.join(h.state, "session.default.etf")
        saved_a, a = persist_dump(session)
        if verbose:
            print("--- dump A", a, sep="\n", end="")
        ok(f'cwd="{dir_b}"' in a and f'cwd="{dir_c}"' in a,
           "persist run 1: the session file records the dir-b and dir-c cwds")
        ok(len(re.findall(r"^tab=", a, re.M)) == 2 and re.search(r"root=h\(", a),
           "persist run 1: the session file has two tabs and a side-by-side split")
        s1 = log_json(h.log)
        ok(s1["restores"]["none"] == 1 and s1["persist_writes"] >= 1 and s1["persist_errors"] == 0,
           f"persist run 1: log has a fresh start, writes, no errors ({s1['restores']},"
           f" writes {s1['persist_writes']}, errors {s1['persist_errors']})")

        # run 2: same state dir, a new log, sockets and runtime dir; the probe-reply count
        # follows the transcript, so it starts empty again
        del transcript[:]
        h = Herdr(tmp, cols, rows, run=".2")
        h.start()
        h.until(lambda: re.search(r"herdr-event persist_restore .*source=disk", read_text(h.log)),
                "persist_restore source=disk in the run 2 log", timeout=60)
        line = re.search(r"herdr-event persist_restore .*", read_text(h.log)).group(0)
        ok("reason=boot" in line, f"persist run 2: log has {line.strip()}")
        h.until(lambda: h.shows("m8-marker-b"), "m8-marker-b replayed in run 2", timeout=60)
        ok(True, "persist run 2: m8-marker-b from run 1's scrollback is on screen")
        h.until(lambda: h.prompts() >= 2, "two prompts on tab 1 in run 2", timeout=30)
        # the comparison prints a short word whatever the cwd's length
        h.send(f'case $(pwd -P) in {dir_b}) echo cwd-""is-b ;; *) pwd ;; esac\r'.encode())
        h.until(lambda: h.shows("cwd-is-b"), "pwd of the focused pane is dir-b", timeout=30)
        ok(True, f"persist run 2: pwd in the focused pane is {dir_b}")
        end = time.monotonic() + 3
        while time.monotonic() < end:
            h.pump(0.1)
        h.quit()
        saved_b, b = persist_dump(session)
        if verbose:
            print("--- dump B", b, sep="\n", end="")
        if a != b:
            print("--- dump A", a, "--- dump B", b, sep="\n", end="", file=sys.stderr)
        ok(a == b, "persist: stop, start, identical layout and cwds (dump A == dump B)")
        s2 = log_json(h.log)
        ok(s2["persist_writes"] >= 1 and saved_b > saved_a,
           f"persist run 2: wrote the session file again (writes {s2['persist_writes']},"
           f" saved_at {saved_a} -> {saved_b})")
        ok(s2["restores"] == {"disk": 1, "boot": 1, "fallback": 0, "none": 0}
           and s2["persist_errors"] == 0 and s2["session_losses"] == 0,
           f"persist run 2: log summary restores {s2['restores']}, errors {s2['persist_errors']},"
           f" session_losses {s2['session_losses']}")
    if verbose:
        print("--- screen", h.screen.text(), sep="\n")


def agent():
    with tempfile.TemporaryDirectory() as tmp:
        compile_then_start_clock(tmp)
        h = Herdr(tmp, 120, 40)
        h.start()
        t = lambda name: os.path.join(tmp, name)

        def shell(cmd, done, label, timeout=60):
            """Types `cmd` into the focused (first) pane, then waits for `touch done`."""
            h.send(f"{cmd}; touch {t(done)}\r".encode())
            h.until(lambda: os.path.exists(t(done)), label, timeout=timeout)

        bin_ = '"$HERDR_LIVE_BIN"'
        shell(f'echo "$HERDR_PANE_ID" > {t("me.txt")}; {bin_} pane split --direction right > {t("split.json")}',
              "s1", "pane split from the pane")
        h.until(lambda: h.prompts() >= 2, "two prompts after pane split", timeout=30)
        try:
            split = json.load(open(t("split.json")))
            new = split["pane"]["pane_id"]
        except (OSError, ValueError, KeyError, TypeError) as e:
            fail(f"agent: split.json has no pane.pane_id ({e}: {open(t('split.json')).read()!r})")
        ok(isinstance(new, str) and new.startswith("p"), f"agent: pane split printed pane.pane_id {new}")
        shell(f"{bin_} pane run {new} 'echo agent-\"\"marker' > {t('run.json')}"
              f" && {bin_} pane wait-output {new} --match agent-marker --timeout 10000 > {t('wait.json')}"
              f"; {bin_} pane read {new} > {t('read.txt')}", "s2", "pane run, wait-output and read")
        read = open(t("read.txt")).read()
        ok("agent-marker" in read, "agent: pane read of the new pane contains agent-marker")
        shell(f"{bin_} pane list > {t('list.json')}; {bin_} agent list 2> {t('agent.err')}", "s3",
              "pane list and agent list")
        me = open(t("me.txt")).read().strip()
        try:
            ids = [p["pane_id"] for p in json.load(open(t("list.json")))["panes"]]
        except (OSError, ValueError, KeyError, TypeError) as e:
            fail(f"agent: pane list output unreadable ({e})")
        ok(len(ids) == 2 and me in ids and new in ids,
           f"agent: pane list has 2 panes with the caller's HERDR_PANE_ID {me} ({ids})")
        err = open(t("agent.err")).read()
        ok('"code":"not_available"' in err, f"agent: agent list answers not_available ({err.strip()})")
        shell(f"a=$(date +%s%N); i=0; while [ $i -lt 10 ]; do {bin_} ping > /dev/null || echo x >> {t('pingfail')};"
              f" i=$((i + 1)); done; b=$(date +%s%N); echo $(((b - a) / 10000000)) > {t('lat.txt')}",
              "s4", "10 timed pings", timeout=90)
        ok(not os.path.exists(t("pingfail")), "agent: 10 pings from the pane succeeded")
        lat = open(t("lat.txt")).read().strip()
        ok(lat.isdigit(), f"agent: ping latency {lat} ms mean over 10 CLI calls from a pane")
        h.quit()
        s = json.loads(subprocess.run([sys.executable, os.path.join(LIVE, "scripts", "log_summary.py"),
                                       h.log, "--json"], capture_output=True, text=True, check=True).stdout)
        ok(s["api"]["connects"] >= 5, f"agent: log summary api connects >= 5 ({s['api']})")
        ok(s["session_losses"] == 0, f"agent: log summary session_losses 0 ({s['session_losses']})")
    if verbose:
        print("--- screen", h.screen.text(), sep="\n")


def remote():
    global DEADLINE
    # under /tmp: short socket paths (api.sock, client.sock beside it)
    with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
        tmp = os.path.realpath(tmp)
        compile_then_start_clock(tmp)
        DEADLINE += 180
        pidfile, clog = os.path.join(tmp, "relay.pid"), os.path.join(tmp, "client.log")
        events = lambda kind: re.findall(rf"herdr-event {kind}\b.*", read_text(a.log))
        a = Herdr(tmp, 120, 40)
        try:
            a.start()
            b = Herdr(tmp, 80, 24, args=("attach", "fakehost"), extra_env={
                "HERDR_LIVE_SSH": os.path.join(LIVE, "bench", "remote", "fake_ssh.sh"),
                "HERDR_LIVE_REMOTE_BIN": os.path.join(LIVE, "bin", "herdr-live"),
                "HERDR_LIVE_FAKE_SSH_PIDFILE": pidfile, "HERDR_LIVE_CLIENT_LOG": clog})
            b.until(lambda: ALT_ON in b.transcript and len(b.screen.rows()) >= 24
                    and b.screen.rows()[23].startswith("TERMINAL") and b.prompts() >= 1,
                    "B: first frame with TERMINAL on row 24 and a prompt", timeout=120)
            ok(len(a.screen.rows()) >= 40 and a.screen.rows()[39].startswith("TERMINAL"),
               "remote: B (80x24, attach fakehost over fake_ssh) shows TERMINAL on row 24, A on row 40")
            attach = events("client_attach")
            ok(len(attach) >= 1, f"remote: server log has {attach[-1] if attach else 'client_attach'}")
            cid = re.search(r"\bid=(\S+)", attach[-1]).group(1)

            b.send(b'echo from-""b\r')
            a.until(lambda: a.shows("from-b"), "B's echo from-b on A's screen", timeout=30)
            ok(True, "remote: echo from-b typed in B shows on A")
            a.send(b'echo from-""a\r')
            b.until(lambda: b.shows("from-a"), "A's echo from-a on B's screen", timeout=30)
            ok(True, "remote: echo from-a typed in A shows on B")

            b.until(lambda: os.path.exists(pidfile) and read_text(pidfile).strip().isdigit(),
                    "the relay's pid file", timeout=30)
            relay = int(read_text(pidfile).strip())
            os.remove(pidfile)
            at, before = len(b.transcript), len(events("client_reconnect"))
            os.kill(relay, signal.SIGKILL)  # a port child of B's VM, in its own process group; the first relay is only this pid
            # (fake_ssh execs the relay, nothing else in its group), so cleanup needs the second
            b.until(lambda: b"reconnecting" in b.transcript[at:], "B shows reconnecting", timeout=30)
            ok(True, f"remote: killing the relay (pid {relay}) shows reconnecting in B")
            b.until(lambda: len(events("client_reconnect")) > before and not b.shows("reconnecting"),
                    "client_reconnect in the log and the notice cleared", timeout=60)
            ok(True, f"remote: B reconnected ({events('client_reconnect')[-1].strip()})")
            b.send(b'echo after-""drop\r')
            a.until(lambda: a.shows("after-drop"), "after-drop from B on A", timeout=30)
            ok(True, "remote: echo after-drop typed in B shows on A")

            reconnects, held = len(events("client_reconnect")), len(events("client_held"))
            code, out = a.cli("kernel-restart", timeout=120)
            ok(code == 0, f"remote: herdr-live kernel-restart exits 0 ({out.strip()})")
            a.until(lambda: re.search(r"handoff graceful g\d+", a.screen.text()),
                    "handoff graceful g<gen> on A", timeout=60)
            b.until(lambda: len(events("client_held")) > held, "client_held after the restart", timeout=60)
            b.send(b'echo after-""restart\r')
            a.until(lambda: a.shows("after-restart"), "after-restart from B on A", timeout=60)
            ok(True, "remote: after kernel-restart, echo after-restart typed in B shows on A")
            # a resync after a bad frame waits the longest backoff (5 s): outlast it
            end = time.monotonic() + REMOTE_BACKOFF_WINDOW
            while time.monotonic() < end:
                pump_all()
            ok("cannot decode" not in read_text(clog), "remote: the client decoded every server frame")
            new_held = events("client_held")[held:]
            new_rec = [l for l in events("client_reconnect")[reconnects:] if f"id={cid}" in l]
            carried = [l for l in new_held if f"id={cid}" in l and "carried=true" in l]
            if not carried or new_rec:
                print("--- client events", *events("client_\\w+"), sep="\n", file=sys.stderr)
            ok(carried, f"remote: handoff carried B's socket ({(carried or new_held or ['none'])[0].strip()})")
            ok(not new_rec, f"remote: no client_reconnect for B ({cid}) across the handoff ({new_rec})")

            b.quit()
            a.send(b'echo a-""still\r')
            a.until(lambda: a.shows("a-still"), "A answers after B quit", timeout=30)
            ok(True, "remote: prefix q ended only B, A still runs")
            a.quit()
        except SystemExit:
            for name, path in (("client log", clog), ("server log", a.log)):
                if os.path.exists(path):
                    print(f"--- {name}", read_text(path)[-6000:] if not verbose else read_text(path), sep="\n", file=sys.stderr)
            raise
        finally:
            # the reconnected relay (fake_ssh's pid file) leads its own group, not ours
            try:
                pg = os.getpgid(int(read_text(pidfile).strip()))
                if pg != os.getpgrp():
                    os.killpg(pg, signal.SIGKILL)
            except (OSError, ValueError):
                pass
        s = log_json(a.log)
        ok(s["clients"]["attaches"] >= 2 and s["session_losses"] == 0,
           f"remote: log summary clients {s['clients']}, session_losses {s['session_losses']}")
    if verbose:
        print("--- B screen", b.screen.text(), sep="\n")


def plugins():
    """Two of herdr's example plugins, unmodified, end to end (M14's exit criterion)."""
    global DEADLINE
    with tempfile.TemporaryDirectory() as tmp:
        compile_then_start_clock(tmp)
        # about 25 sequential waits, each a CLI round trip or more: 300 s, not 120 (a loaded
        # host, Linux podman)
        DEADLINE += 180
        t = lambda *name: os.path.join(tmp, *name)
        # offline stubs first on the PATH: github-link-preview's preview.sh calls gh (network),
        # dev-layout-bootstrap's setup.lua runs `nvim .` in the first pane
        os.makedirs(t("bin"))
        for name, body in (("gh", 'echo "stub-gh $*"'), ("nvim", "echo stub-nvim")):
            with open(t("bin", name), "w") as f:
                f.write(f"#!/bin/sh\n{body}\n")
            os.chmod(t("bin", name), 0o755)
        path = t("bin") + os.pathsep + os.environ.get("PATH", "")
        if not shutil.which("lua", path=path):
            fail("plugins: dev-layout-bootstrap runs `lua setup.lua`: no lua on PATH (brew install lua, apt install lua5.4)")
        h = Herdr(tmp, 120, 40, extra_env={"PATH": path, "XDG_CONFIG_HOME": t("xdg-config"),
                                           "XDG_STATE_HOME": t("xdg-state")})
        h.start()
        examples = os.path.join(os.path.dirname(LIVE), "vendor", "herdr-plugin-examples")
        layout, preview = "examples.dev-layout-bootstrap", "examples.github-link-preview"
        bin_ = '"$HERDR_LIVE_BIN"'

        def shell(cmd, done, label, timeout=60):
            """Types `cmd` into the focused (first) pane, then waits for `touch done`."""
            h.send(f"{cmd}; touch {t(done)}\r".encode())
            h.until(lambda: os.path.exists(t(done)), label, timeout=timeout)

        def cli_json(*args):
            code, out = h.cli(*args)
            if code != 0:
                fail(f"plugins: herdr-live {' '.join(args)} exits {code} ({out.strip()[-300:]})")
            return json.loads(out)

        def listed():
            return {p["plugin_id"]: p for p in cli_json("plugin", "list", "--json")["plugins"]}

        def panes():
            return cli_json("pane", "list")["panes"]

        def logs(plugin):
            return cli_json("plugin", "log", "list", "--plugin", plugin)["logs"]

        def ended(plugin, log_id):
            """The record `log_id` (the invoke's answer) once it is no longer running."""
            return next((r for r in logs(plugin) if r.get("log_id") == log_id and r.get("status") != "running"),
                        None)

        # 1. install both from the first pane's shell
        shell(f"{bin_} plugin install {examples}/dev-layout-bootstrap --yes > {t('i1.json')} 2>&1"
              f"; {bin_} plugin install {examples}/github-link-preview --yes > {t('i2.json')} 2>&1",
              "s1", "plugin install of both examples")
        got = listed()
        ok(all(got.get(i, {}).get("enabled") and not got[i].get("error") for i in (layout, preview)),
           "plugins: install of dev-layout-bootstrap and github-link-preview, both listed enabled without error"
           + ("" if all(i in got for i in (layout, preview))
              else f" ({read_text(t('i1.json'))[-300:]} {read_text(t('i2.json'))[-300:]})"))

        # 2. dev layout: three named panes
        shell(f"echo \"$HERDR_PANE_ID\" > {t('me.txt')}; {bin_} plugin action invoke {layout}.setup"
              f" > {t('inv.json')} 2>&1", "s2", "plugin action invoke setup")
        try:
            setup = json.loads(read_text(t("inv.json")))["log"]["log_id"]
        except (OSError, ValueError, KeyError, TypeError) as e:
            fail(f"plugins: invoke answer has no log.log_id ({e}: {read_text(t('inv.json'))!r})")
        run = h.until(lambda: ended(layout, setup), "the setup run to end", timeout=60)
        ok(run.get("status") == "succeeded", f"plugins: plugin log has the setup run succeeded"
           f" (exit {run.get('exit_code')}, stdout {run.get('stdout', '')[:40]!r})")
        names = {p.get("label"): p["pane_id"] for p in panes()}
        ok(len(names) == 3 and {"editor", "files", "tasks"} <= set(names),
           f"plugins: dev-layout-bootstrap made 3 panes named editor, files, tasks ({names})")
        editor = read_text(t("me.txt")).strip()
        ok(names["editor"] == editor, f"plugins: the editor is the invoking pane {editor}")
        h.until(lambda: "ready." in h.cli("pane", "read", names["files"])[1], "ready. in the files pane", timeout=30)
        h.until(lambda: "stub-nvim" in h.cli("pane", "read", editor)[1], "stub-nvim in the editor pane", timeout=30)
        ok(True, "plugins: files pane shows ready., editor ran the stub nvim")

        # 3. an OSC 8 link in the editor, ctrl+clicked through the pty
        url = "https://github.com/ogulcancelik/herdr/issues/1"
        with open(t("link.sh"), "w") as f:
            f.write(f"printf '\\033]8;;{url}\\033\\\\issue-link\\033]8;;\\033\\\\\\n'\n")
        shell(f"clear; sh {t('link.sh')}", "s3", "the OSC 8 link printed")
        h.until(lambda: h.shows("issue-link"), "issue-link on the screen", timeout=30)
        y, x = next((y, r.index("issue-link")) for y, r in enumerate(h.screen.rows()) if "issue-link" in r)

        def previews():
            return [p["pane_id"] for p in panes() if p.get("label") == "GitHub preview"]

        def preview_text(pane):
            text = h.cli("pane", "read", pane)[1]
            return text if "github issues #1" in text and "stub-gh issue view 1" in text else None

        at = f"{x + 3};{y + 1}".encode()
        h.send(b"\x1b[<16;" + at + b"M\x1b[<16;" + at + b"m")
        first = h.until(lambda: previews(), "a GitHub preview pane after the ctrl+click", timeout=60)[0]
        text = h.until(lambda: preview_text(first), "github issues #1 and stub-gh in the preview", timeout=30)
        ok(True, f"plugins: ctrl+click at screen ({x + 2},{y}) opened GitHub preview {first} with github issues #1"
                 " and the stub gh output")
        cli_json("pane", "close", first)
        h.until(lambda: not previews(), "the preview closed", timeout=30)
        # `clear` before the link: it sits at the editor's viewport row 0, col 0
        act = cli_json("pane", "link", "activate", editor, "--col", "2", "--row", "0", "--modifier", "ctrl")
        ok(act.get("url") == url and act.get("handled") is True, f"plugins: pane link activate handled {act}")
        second = h.until(lambda: previews(), "a GitHub preview pane after pane link activate", timeout=60)[0]
        h.until(lambda: preview_text(second), "the second preview's text", timeout=30)
        ok(True, f"plugins: pane link activate over the API opened GitHub preview {second}")
        cli_json("pane", "close", second)

        # 4. a manifest without version, then a linked plugin whose manifest breaks
        os.makedirs(t("broken"))
        with open(t("broken", "herdr-plugin.toml"), "w") as f:
            f.write('id = "smoke.broken"\nname = "Broken"\nmin_herdr_version = "0.7.0"\n')
        code, out = h.cli("plugin", "link", t("broken"))
        ok(code != 0 and "invalid_plugin_version" in out, f"plugins: link without version fails ({out.strip()})")
        os.makedirs(t("good"))
        manifest = t("good", "herdr-plugin.toml")
        with open(manifest, "w") as f:
            f.write('id = "smoke.good"\nname = "Good"\nversion = "0.1.0"\nmin_herdr_version = "0.7.0"\n'
                    '[[actions]]\nid = "hi"\ntitle = "Hi"\ncommand = ["echo", "hi"]\n')
        cli_json("plugin", "link", t("good"))
        with open(manifest, "w") as f:
            f.write("id = [\n")
        got = listed()
        err = got.get("smoke.good", {}).get("error")
        ok(err, f"plugins: a corrupted manifest lists with error ({err})")
        ok(all(not got[i].get("error") for i in (layout, preview)), "plugins: the two examples list without error")
        for plugin, action in ((preview, "open"), ("smoke.good", "hi")):
            code, out = h.cli("plugin", "action", "invoke", f"{plugin}.{action}")
            if plugin == "smoke.good":
                ok(code != 0 and '"code":"not_found"' in out and "plugin_action_not_found" in out,
                   f"plugins: the broken plugin cannot run ({out.strip()})")
            else:
                if code != 0:
                    fail(f"plugins: {plugin}.{action} invoke failed ({out.strip()})")
                opened = json.loads(out)["log"]["log_id"]
                rec = h.until(lambda: ended(preview, opened), f"{preview}.open to end", timeout=30)
                ok(rec["status"] == "succeeded", f"plugins: {preview}.open still runs (succeeded)")
        h.until(lambda: "plugin: smoke.good:" in read_text(h.log), "the plugin warning line", timeout=30)
        ok(True, "plugins: the log has a plugin warning line for smoke.good")

        # 5. disable, enable, uninstall
        cli_json("plugin", "disable", preview)
        code, out = h.cli("plugin", "action", "invoke", f"{preview}.open")
        ok(code != 0 and "plugin_disabled" in out, f"plugins: invoke of a disabled plugin fails ({out.strip()})")
        cli_json("plugin", "enable", preview)
        ok(listed()[preview].get("enabled"), "plugins: plugin enable")
        cli_json("plugin", "uninstall", preview)
        got = listed()
        ok(preview not in got and layout in got, f"plugins: uninstall lists without it ({sorted(got)})")
        h.quit()
        s = log_json(h.log)
        ok(s["session_losses"] == 0, f"plugins: log summary session_losses 0 ({s['session_losses']})")
    if verbose:
        print("--- screen", h.screen.text(), sep="\n")


if __name__ == "__main__":
    modes = {"destructor": destructor, "demo": demo, "herdr": herdr, "herdr-stress": herdr_stress,
             "selfhost": selfhost, "persist": persist, "agent": agent, "remote": remote,
             "plugins": plugins,
             "broker-kill": broker_kill}
    args = [a for a in sys.argv[1:] if a != "-v"]
    if len(args) != 1 or args[0] not in modes:
        sys.exit(__doc__)
    # a pane of a running herdr-live inherits the VM's env: these modes would compile into
    # and reload that instance's own _build
    if args[0] in ("herdr", "herdr-stress", "selfhost", "persist", "agent", "remote", "plugins", "broker-kill") and os.environ.get("HERDR_BROKER_SOCK"):
        print(f"SKIP: {args[0]}: running inside herdr-live (run live-check outside it, see editing-live.md)")
        sys.exit(0)
    # CI cancellation: let `finally` kill the process groups.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        modes[args[0]]()
    finally:
        kill_all()
