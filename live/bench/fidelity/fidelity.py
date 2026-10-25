#!/usr/bin/env python3
"""M9 terminal-fidelity checks: herdr-live attached in a 120x40 pty, this script the host.

Usage: fidelity.py [-v] [CHECK ...]

Launches bin/herdr-live like scripts/tty_harness.py's `herdr` mode (imported by path:
its Herdr launch with an isolated log, API socket, HERDR_LIVE_RUNTIME_DIR and
HERDR_LIVE_STATE_DIR, its Screen and probe answers) with SSH_TTY=1 (clipboard writes go to the
host as OSC 52, never to this machine's clipboard). The host also answers the client's
colour queries: OSC 10 fg rgb:dddd/eeee/ffff, OSC 11 bg rgb:1111/2222/3333, OSC 4 palette,
`CSI ? 996 n` (dark) and the `CSI 5 n` sentinel. Each check runs in a new tab (prefix c,
enter at M13's tab-name prompt)
and prints `PASS <name> ...` or `FAIL <name>: reason`; exits 1 if any failed. Skips
(SKIP line, exit 0) inside a herdr-live pane. Reflow against herdr is reflow.py.
"""
import base64
import importlib.util
import os
import re
import select
import signal
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
LIVE = os.path.dirname(os.path.dirname(HERE))
spec = importlib.util.spec_from_file_location("tty_harness", os.path.join(LIVE, "scripts", "tty_harness.py"))
th = importlib.util.module_from_spec(spec)
spec.loader.exec_module(th)

BG, FG = b"rgb:1111/2222/3333", b"rgb:dddd/eeee/ffff"
HOST_QUERY = re.compile(rb"\x1b\](1[01]);\?(?:\x07|\x1b\\)|\x1b\]4;(\d+);\?(?:\x07|\x1b\\)|\x1b\[\?996n|\x1b\[5n")
CHECK_TIMEOUT = 180  # host load can be very high: poll generously
PREFIX = b"\x02"
verbose = "-v" in sys.argv


class CheckFail(Exception):
    pass


def _fail(msg):
    raise CheckFail(msg)


th.fail = _fail  # the harness's waits raise instead of exiting
th.ok = lambda cond, msg: cond or _fail(msg)  # and print no PASS lines of their own


class Host(th.Herdr):
    """th.Herdr whose host also answers the colour queries."""

    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self.scanned = 0

    def pump(self, wait=0.05):
        super().pump(wait)
        buf = bytes(th.transcript[self.scanned:])
        # rescan a 64-byte tail next time: a query split across reads (the longest,
        # `ESC ] 4 ; 255 ; ? ESC \`, is 12 bytes) is answered once it is whole
        end = 0
        for m in HOST_QUERY.finditer(buf):
            self.send(answer(m))
            end = m.end()
        self.scanned += max(end, len(buf) - 64, 0)

    def wait(self, check, label, timeout=CHECK_TIMEOUT):
        return self.until(check, label, timeout)

    def since(self, at):
        return bytes(th.transcript[at:])

    def run(self, cmd, label):
        """Types `cmd` at the focused prompt, then waits for a unique marker echoed after it."""
        marker = f"done-{time.monotonic_ns()}"
        self.send(cmd.encode() + f'; echo {marker[:4]}""{marker[4:]}\r'.encode())
        self.wait(lambda: self.marker_row(marker) is not None, label)

    def marker_row(self, text):
        """The row index of the screen row containing `text` (last one), or None."""
        rows = self.screen.rows()
        for y in range(len(rows) - 1, -1, -1):
            if text in rows[y]:
                return y
        return None

    def find(self, text, exclude="echo"):
        """(x, y) of the last on-screen `text` on a row without `exclude` (the typed command)."""
        rows = self.screen.rows()
        for y in range(len(rows) - 1, -1, -1):
            if text in rows[y] and exclude not in rows[y]:
                return rows[y].index(text), y
        return None

    def new_tab(self, name):
        # prefix c opens M13's tab-name prompt; enter keeps the suggested name
        self.send(PREFIX + b"c")
        self.wait(lambda: self.shows("new tab") and self.shows("save"), f"the tab name prompt for {name}")
        self.send(b"\r")
        self.run(f"echo tab-{name}", f"a prompt in a new tab for {name}")

    def sgr(self, button, x, y, release=False):
        self.send(f"\x1b[<{button};{x + 1};{y + 1}{'m' if release else 'M'}".encode())


def answer(m):
    q = m.group(0)
    if m.group(1):
        return b"\x1b]" + m.group(1) + b";" + (FG if m.group(1) == b"10" else BG) + b"\x1b\\"
    if m.group(2):
        n = int(m.group(2))
        return b"\x1b]4;%d;rgb:%02x%02x/%02x%02x/%02x%02x\x1b\\" % (n, n, n, n, n, 255 - n, 255 - n)
    if q == b"\x1b[?996n":
        return b"\x1b[?997;1n"
    return b"\x1b[0n"


def osc52(text):
    return b"\x1b]52;c;" + base64.b64encode(text.encode()) + b"\x07"


# --- checks: each returns a PASS detail string or raises CheckFail


def check_queries(h, tmp):
    out = os.path.join(tmp, "queries.txt")
    h.run(f"python3 '{os.path.join(HERE, 'child_queries.py')}' '{out}' 20", "child_queries.py to finish")
    lines = dict(line.split(" ", 1) for line in open(out).read().splitlines())
    detail = "; ".join(f"{k}={v}" for k, v in lines.items())
    bad = [k for k, v in lines.items() if v.startswith("(")]
    if bad:
        raise CheckFail(f"unanswered: {', '.join(bad)} ({detail})")
    for name, want in (("DA1", "\\x1b[?"), ("XTVERSION", "libghostty"), ("DECRQM2004", "[?2004;")):
        if want not in lines.get(name, "") or (name == "DA1" and not lines[name].startswith(want)):
            raise CheckFail(f"{name} reply {lines.get(name)!r} lacks {want!r}")
    if BG.decode() not in lines.get("OSC11", ""):
        raise CheckFail(f"OSC 11 reply {lines.get('OSC11')!r} lacks the host bg {BG.decode()}")
    return detail


def check_wheel_scroll(h, tmp):
    h.run("seq 1 500", "seq 1 500")
    x, y, lowest = seq_shown(h)
    for _ in range(3):
        h.sgr(64, x, y - 5)
    h.wait(lambda: min(numbers(h, x), default=lowest) <= lowest - 9 and scrollbar(h),
           "earlier numbers and a scrollbar column after 3 wheel notches")
    shown = lowest - min(numbers(h, x))
    h.send(b"z")
    h.wait(lambda: not scrollbar(h) and h.find("$ z", exclude="seq") is not None, "typing snaps to the bottom")
    h.send(b"\x7f")
    return f"3 notches scrolled {shown} lines, scrollbar shown, typing snapped back"


def seq_shown(h):
    """(column, row, lowest number) of `seq 1 500`'s output. The row is the one whose number
    is 500 alone: `run`'s marker `done-<ns>` holds "500" in about 1 run of 70, and
    `find("500")` then took the marker's column (M9's page_up flake: `min()` of an empty
    list, or a PageUp that scrolled but was never seen)."""
    got = []

    def shown():
        rows = h.screen.rows()
        for y in range(len(rows) - 1, -1, -1):
            m = re.search(r"(?<![\w-])500(?!\S)", rows[y])
            if m and 500 in numbers(h, m.start()):
                got.append((m.start(), y, min(numbers(h, m.start()))))
                return True
        return False

    h.wait(shown, "a row with the number 500 alone after seq 1 500")
    return got[-1]


def numbers(h, col):
    """The seq numbers shown at column `col` (where the pane's content starts)."""
    got = []
    for r in h.screen.rows():
        m = re.match(r"\d{1,3}(?!\S)", r[col:col + 4])
        if m:
            got.append(int(m.group(0)))
    return got


def scrollbar(h):
    """A scrollbar glyph in the rightmost column of some row."""
    return any(r.rstrip().endswith(("\u2595", "\u2590")) for r in h.screen.rows())


def check_page_up(h, tmp):
    h.run("seq 1 500", "seq 1 500")
    x, _, lowest = seq_shown(h)
    h.send(b"\x1b[5~")
    h.wait(lambda: min(numbers(h, x), default=lowest) <= lowest - 20, "PageUp shows an earlier page")
    moved = lowest - min(numbers(h, x))
    h.send(b"z")
    h.wait(lambda: not scrollbar(h), "typing snaps to the bottom after PageUp")
    h.send(b"\x7f")
    return f"PageUp scrolled {moved} lines"


def drag(h, word):
    x, y = h.find(word)
    at = len(th.transcript)
    h.sgr(0, x, y)
    h.sgr(32, x + 2, y)
    h.sgr(32, x + len(word) - 1, y)
    h.sgr(0, x + len(word) - 1, y, release=True)
    return at


def check_selection_osc52(h, tmp):
    h.run("echo hello", "echo hello")
    at = drag(h, "hello")
    want = osc52("hello")
    h.wait(lambda: want in h.since(at), f"{want!r} on the host after a drag over hello")
    return f"drag over hello -> {want!r}"


def check_double_click_word(h, tmp):
    h.run("echo foo dblword bar", "echo dblword")
    x, y = h.find("dblword")
    at = len(th.transcript)
    for _ in range(2):
        h.sgr(0, x + 3, y)
        h.sgr(0, x + 3, y, release=True)
    want = osc52("dblword")
    h.wait(lambda: want in h.since(at), f"{want!r} after a double click on dblword")
    return f"double click -> {want!r}"


def check_child_osc52(h, tmp):
    at = len(th.transcript)
    h.run("printf '\\033]52;c;%s\\007' \"$(printf hi | base64)\"", "child OSC 52")
    want = osc52("hi")
    h.wait(lambda: want in h.since(at), f"{want!r} forwarded to the host")
    return f"forwarded {want!r}"


OSC = re.compile(rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


def check_bell(h, tmp):
    at = len(th.transcript)
    h.run("printf '\\007'", "printf BEL")
    h.wait(lambda: b"\x07" in OSC.sub(b"", h.since(at)), "a BEL on the host")
    return "child BEL -> host BEL"


PASTE_BYTES = 4 * 1024 * 1024


def check_paste_4mib(h, tmp):
    """4 MiB of 64-byte lines pasted (bracketed by the host) into `cat > file` with echo
    off; the shell has not enabled 2004, so the file must hold exactly the payload."""
    out, count = os.path.join(tmp, "paste.bin"), os.path.join(tmp, "paste.count")
    h.send(f"stty -echo; cat > '{out}'; stty echo; wc -c < '{out}' > '{count}'\r".encode())
    settle(h, 1.0)
    data = (b"p" * 63 + b"\n") * (PASTE_BYTES // 64)
    t0 = time.monotonic()
    write_pumping(h, b"\x1b[200~" + data + b"\x1b[201~")
    size = lambda: os.path.exists(out) and os.path.getsize(out)  # noqa: E731
    try:
        h.wait(lambda: size() >= PASTE_BYTES, f"{PASTE_BYTES} bytes in the file", timeout=600)
    except CheckFail:
        pass  # short: the count below says by how much
    took = time.monotonic() - t0
    settle(h, 1.0)
    h.send(b"\x04")  # the payload ends in a newline: ^D at a line start ends cat
    h.wait(lambda: os.path.exists(count) and open(count).read().strip(), "wc -c output after ^D")
    n = int(open(count).read())
    if n != PASTE_BYTES:
        raise CheckFail(f"wc -c counted {n}, not {PASTE_BYTES}")
    if open(out, "rb").read() != data:
        raise CheckFail("the pasted file differs from the payload")
    return f"wc -c counted {n}, content identical ({took:.1f} s)"


def write_pumping(h, data, chunk=16384):
    """Writes `data` to the host side without blocking, pumping output meanwhile."""
    os.set_blocking(h.master, False)
    try:
        i = 0
        while i < len(data):
            if time.monotonic() > th.DEADLINE:
                raise CheckFail(f"paste write stalled at {i} bytes")
            if select.select([], [h.master], [], 0.05)[1]:
                try:
                    i += os.write(h.master, data[i:i + chunk])
                except BlockingIOError:
                    pass
            h.pump(0)
    finally:
        os.set_blocking(h.master, True)


def check_bracketed(h, tmp):
    h.send(b"printf '\\033[?2004h'; cat -v\r")
    settle(h, 1.0)
    h.send(b"\x1b[200~bpaste\x1b[201~")
    h.send(b"\r")
    h.wait(lambda: h.find("^[[200~bpaste^[[201~") is not None, "cat -v showing ^[[200~bpaste^[[201~")
    h.send(b"\x03")
    h.run("printf '\\033[?2004l'", "bracketed mode off")
    return "cat -v shows ^[[200~bpaste^[[201~"


def settle(h, quiet=0.5, cap=20):
    """Pumps until the host sees no output for `quiet` seconds."""
    end = time.monotonic() + cap
    while time.monotonic() < end:
        n = len(th.transcript)
        h.pump(quiet)
        if len(th.transcript) == n:
            return


def split(h):
    """prefix v: two side-by-side panes (two top borders on one row), the new one focused."""
    h.send(PREFIX + b"v")
    h.wait(lambda: any("┐┌" in r for r in h.screen.rows()), "two panes after prefix v")
    settle(h)


def check_focus(h, tmp):
    split(h)
    h.send(b"printf '\\033[?1004h'; cat -v\r")
    settle(h)
    h.send(PREFIX + b"h")
    h.wait(lambda: "^[[O" in h.screen.text(), "^[[O in the right pane after prefix h")
    h.send(PREFIX + b"l")
    h.wait(lambda: "^[[I" in h.screen.text(), "^[[I after prefix l")
    h.send(b"\x03")
    h.run("printf '\\033[?1004l'", "focus mode off")
    return "focus out ^[[O and in ^[[I reached the child"


SGR_UNDERLINE = re.compile(rb"\x1b\[(?:[0-9:]*;)*4(?::\d)?(?:;[0-9:]*)*m")


def check_hover_link(h, tmp):
    h.run("echo https://example.com/fidelity", "echo a URL")
    x, y = h.find("https://example.com/fidelity")
    settle(h)
    at = len(th.transcript)
    h.sgr(35 + 16, x + 5, y)
    h.wait(lambda: underlined(h.since(at)), "an SGR underline on the URL after ctrl+move over it")
    h.sgr(35, x + 5, y + 3)
    return f"ctrl+move over the URL -> SGR underline on {underlined(h.since(at))!r}"


def underlined(out):
    """The visible text right after the first SGR underline in `out` if it is URL text."""
    for m in SGR_UNDERLINE.finditer(out):
        text = th.Screen.SEQ.split(out[m.end():m.end() + 200].decode("utf-8", "replace"))[0]
        if "example.com" in text or text.startswith("https"):
            return text.strip()
    return None


def check_title(h, tmp):
    # split, so panes have borders (a lone pane has none; the status row shows the title)
    split(h)
    h.run("printf '\\033]2;fid%s\\007' title", "OSC 2 title")
    border = re.compile(r"[┌╭][─]*fidtitle")
    at = h.wait(lambda: next((r for r in h.screen.rows() if border.search(r)), None), "fidtitle in a pane border")
    return f"OSC 2 title in the pane's top border: {border.search(at).group(0)[-9:]!r}"


def check_cursor_shape(h, tmp):
    at = len(th.transcript)
    h.run("printf '\\033[5 q'", "DECSCUSR 5")
    h.wait(lambda: b"\x1b[5 q" in h.since(at), "the host receiving CSI 5 SP q")
    h.run("printf '\\033[0 q'", "DECSCUSR 0")
    return "child CSI 5 q -> host CSI 5 q"


def check_copy_mode(h, tmp):
    # no marker echo: the line above the prompt is the output
    h.send(b"echo copyline-xyz\r")
    h.wait(lambda: h.find("copyline-xyz") is not None and h.find("$ ", exclude="copyline") is not None,
           "echo copyline-xyz and a prompt")
    settle(h)
    h.send(PREFIX + b"[")
    h.wait(lambda: any(r.startswith("COPY") or " COPY" in r for r in h.screen.rows()), "COPY in the status row")
    at = len(th.transcript)
    for k in (b"k", b"0", b"v", b"$", b"y"):
        h.send(k)
        settle(h, 0.3, 5)
    got = re.search(rb"\x1b\]52;c;([A-Za-z0-9+/=]*)\x07", h.since(at)) or \
        h.wait(lambda: re.search(rb"\x1b\]52;c;([A-Za-z0-9+/=]*)\x07", h.since(at)), "OSC 52 after y")
    text = base64.b64decode(got.group(1)).decode()
    if text.strip() != "copyline-xyz":
        raise CheckFail(f"copy mode yanked {text!r}, not 'copyline-xyz'")
    return f"prefix [ k 0 v $ y -> OSC 52 {text!r}"


CHECKS = [("queries", check_queries), ("wheel_scroll", check_wheel_scroll), ("page_up", check_page_up),
          ("selection_osc52", check_selection_osc52), ("double_click_word", check_double_click_word),
          ("child_osc52", check_child_osc52), ("bell", check_bell), ("paste_4mib", check_paste_4mib),
          ("bracketed", check_bracketed), ("focus", check_focus), ("hover_link", check_hover_link),
          ("title", check_title), ("cursor_shape", check_cursor_shape), ("copy_mode", check_copy_mode)]


def main():
    names = [a for a in sys.argv[1:] if a != "-v"]
    unknown = set(names) - {n for n, _ in CHECKS}
    if unknown:
        sys.exit(f"unknown checks {sorted(unknown)}; known: {[n for n, _ in CHECKS]}")
    failed = 0
    with tempfile.TemporaryDirectory(prefix="fid", dir="/var/tmp") as tmp:
        th.compile_then_start_clock(tmp)
        th.DEADLINE = time.monotonic() + 3600
        os.environ["SSH_TTY"] = "1"  # Herdr copies os.environ: OSC 52, never the local clipboard
        h = Host(tmp, 120, 40)
        try:
            h.start()
            # the client asks for host colours 500 ms after start: answered, applied
            h.wait(lambda: b"\x1b[5n" in th.transcript, "the client's host colour query")
            settle(h, 1.0)
        except CheckFail as e:
            print(f"FAIL start: {e}")
            if verbose:
                print("--- screen", h.screen.text(), sep="\n")
            return 1
        for name, check in CHECKS:
            if names and name not in names:
                continue
            try:
                h.new_tab(name)
                print(f"PASS {name} {check(h, tmp)}", flush=True)
            except Exception as e:  # noqa: BLE001 - any check error is that check's FAIL
                failed += 1
                print(f"FAIL {name}: {type(e).__name__ + ': ' if not isinstance(e, CheckFail) else ''}{e}",
                      flush=True)
                if verbose:
                    print("--- screen", h.screen.text(), sep="\n")
                h.send(b"\x1b\x03")  # leave copy mode or a running child for the next tab
        h.send(PREFIX + b"q")
        end = time.monotonic() + 60
        while time.monotonic() < end and not os.waitpid(h.pid, os.WNOHANG)[0]:
            h.pump()
    return 1 if failed else 0


if __name__ == "__main__":
    if os.environ.get("HERDR_BROKER_SOCK"):
        print("SKIP: fidelity: running inside herdr-live (run it outside, see editing-live.md)")
        sys.exit(0)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        sys.exit(main())
    finally:
        th.kill_all()
