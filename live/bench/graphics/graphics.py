#!/usr/bin/env python3
"""M10 kitty graphics check: herdr (the herdr-reference build, via bench/gate/herdr_ref.sh,
or HERDR_BIN) and herdr-live, each attached in a 120x40 pty with 10x20-pixel cells
(TIOCSWINSZ ws_xpixel/ws_ypixel), this script the host terminal.

The host keeps a kitty graphics model fed from the multiplexer's output: the cursor (CUP,
CR/LF and printed cells via tty_harness's Screen, plus ESC 7 / ESC 8), images by host id
(pixel size, format) from `a=t`/`a=T` (t=d data, chunked m=1; t=t/t=f paths: the file is
read if it still exists, t=t temp files are then deleted as a host does), placements by
(image id, placement id) with their cell rect and source rect from `a=p`/`a=T`, deletes
(`d=a/A/i/I`), a re-transmitted id dropping its placements, and `ESC [2J` clearing them.
Graphics queries are not answered (both multiplexers send q=2). Cells are ignored.

Scenario: split (prefix v), `draw.py --scroll 3` in the right pane (6 grid placements and
a virtual placement), `kitten icat --place 30x10@2x2` in the left one; resize to 100x30;
wheel 2 notches up over the draw pane; a new tab and back (prefix c, prefix p); close the
draw pane (prefix x, confirm). After each step the visible placements of each pane (cell
rect relative to the pane's content rect, source size, image pixel size) are compared,
herdr against herdr-live, plus checks of each on its own (counts, nothing outside a pane,
scroll moved the draw pane's placements, nothing of the draw pane left after close).
Prints a PASS or FAIL line per step; exit 1 on any FAIL. -v dumps the models and screens.

Usage: graphics.py [-v] [--only herdr|herdr-live]
"""
import base64
import importlib.util
import math
import os
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import types
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
LIVE = os.path.dirname(os.path.dirname(HERE))
CW, CH = 10, 20  # cell size in pixels
PREFIX = b"\x02"
TIMEOUT = 300  # host load can be very high
KITTEN = shutil.which("kitten") or "/opt/homebrew/bin/kitten"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


th = load("tty_harness", os.path.join(LIVE, "scripts", "tty_harness.py"))
glass = load("glass", os.path.join(LIVE, "bench", "gate", "glass.py"))
draw = load("draw", os.path.join(HERE, "draw.py"))
verbose = "-v" in sys.argv


def _pack(fmt, *v):
    if fmt == "HHHH":  # a winsize: add the pixel size the launchers leave at 0
        v = (v[0], v[1], v[1] * CW, v[0] * CH)
    return struct.pack(fmt, *v)


# glass.Term and th.Herdr size their pty with struct.pack("HHHH", rows, cols, 0, 0)
glass.struct = th.struct = types.SimpleNamespace(pack=_pack)


class Failed(Exception):
    pass


class Kitty:
    """The host's kitty graphics state, fed the multiplexer's output stream."""

    TOKEN = re.compile(rb"\x1b_G([^\x1b]*)\x1b\\|\x1b7|\x1b8|\x1b\[[23]J")
    PREFIXES = (b"\x1b", b"\x1b[", b"\x1b[2", b"\x1b[3", b"\x1b_")

    def __init__(self):
        self.screen = th.Screen()
        self.images, self.placements = {}, {}
        self.saved, self.carry, self.chunk, self.notes = (0, 0), b"", None, []

    def feed(self, data):
        buf, pos = self.carry + data, 0
        for m in self.TOKEN.finditer(buf):
            self.screen.feed(buf[pos:m.start()])
            pos, tok = m.end(), m.group(0)
            if tok == b"\x1b7":
                self.saved = (self.screen.x, self.screen.y)
            elif tok == b"\x1b8":
                self.screen.x, self.screen.y = self.saved
            elif tok.startswith(b"\x1b["):
                self.screen.feed(tok)
                self.placements.clear()  # as kitty: erasing the display drops placements
            else:
                self.apc(m.group(1).decode("latin-1"))
        rest = buf[pos:]
        # an unterminated APC, or an escape that may start one of the tokens, waits for more
        cut = rest.rfind(b"\x1b_G")
        if cut < 0 or b"\x1b\\" in rest[cut:]:
            esc = rest.rfind(b"\x1b")
            cut = esc if esc >= 0 and rest[esc:] in self.PREFIXES else len(rest)
        self.screen.feed(rest[:cut])
        self.carry = rest[cut:]

    def apc(self, body):
        control, _, payload = body.partition(";")
        keys = dict(kv.split("=", 1) for kv in control.split(",") if "=" in kv)
        if self.chunk is not None:  # a continuation carries only m (and q)
            self.chunk[1] += payload
            if keys.get("m") == "1":
                return
            keys, payload, self.chunk = self.chunk[0], self.chunk[1], None
        elif keys.get("m") == "1":
            self.chunk = [keys, payload]
            return
        action = keys.get("a", "t")
        if action in ("t", "T"):
            self.transmit(keys, payload)
        if action in ("T", "p"):
            self.put(keys)
        elif action == "d":
            self.delete(keys)

    def transmit(self, keys, payload):
        iid, fmt, medium = int(keys.get("i", 0)), int(keys.get("f", 32)), keys.get("t", "d")
        raw = base64.b64decode(payload + "=" * (-len(payload) % 4))
        if medium == "d":
            data = zlib.decompress(raw) if keys.get("o") == "z" else raw
            nbytes = len(data)
        else:  # a file path (t=f file, t=t temp file, t=s shared memory)
            path = raw.decode("utf-8", "replace")
            data, nbytes = b"", None
            if medium in ("f", "t") and os.path.isfile(path):
                with open(path, "rb") as f:
                    data = f.read()
                nbytes = len(data)
                if medium == "t" and "tty-graphics-protocol" in path:
                    os.unlink(path)  # a host deletes a consumed temp file
            self.notes.append(f"t={medium} {path} {'consumed' if nbytes is None else f'{nbytes} bytes'}")
        w, h = int(keys.get("s", 0)), int(keys.get("v", 0))
        if fmt == 100 and data[12:16] == b"IHDR":
            w, h = struct.unpack(">II", data[16:24])
        # as kitty: a new transmission of an id replaces the image and drops its placements
        self.placements = {k: v for k, v in self.placements.items() if k[0] != iid}
        self.images[iid] = {"size": (w, h), "format": fmt, "bytes": nbytes}

    def put(self, keys):
        iid, pid = int(keys.get("i", 0)), int(keys.get("p", 0))
        if keys.get("U") == "1":
            self.notes.append(f"virtual placement i={iid} p={pid} sent to the host")
            return
        img = self.images.get(iid)
        if img is None:
            self.notes.append(f"a=p of unknown image i={iid}")
            return
        iw, ih = img["size"]
        sx, sy = int(keys.get("x", 0)), int(keys.get("y", 0))
        sw, sh = int(keys.get("w", 0)) or iw - sx, int(keys.get("h", 0)) or ih - sy
        cols = int(keys.get("c", 0)) or math.ceil((sw + int(keys.get("X", 0))) / CW)
        rows = int(keys.get("r", 0)) or math.ceil((sh + int(keys.get("Y", 0))) / CH)
        self.placements[(iid, pid)] = {"x": self.screen.x, "y": self.screen.y, "cols": cols, "rows": rows,
                                       "src": (sx, sy, sw, sh), "z": int(keys.get("z", 0))}

    def delete(self, keys):
        what = keys.get("d", "a")
        if what in ("a", "A"):
            self.placements.clear()
            if what == "A":
                self.images.clear()
        elif what in ("i", "I"):
            iid, pid = int(keys.get("i", 0)), keys.get("p")
            self.placements = {k: v for k, v in self.placements.items()
                               if not (k[0] == iid and (pid is None or k[1] == int(pid)))}
            if what == "I" and not any(k[0] == iid for k in self.placements):
                self.images.pop(iid, None)
        else:
            self.notes.append(f"unmodelled delete d={what}")

    def dump(self):
        lines = [f"images: {self.images}"]
        lines += [f"placement {k}: {v}" for k, v in sorted(self.placements.items())]
        return "\n".join(lines + self.notes[-10:])


def panes(rows):
    """Content rects (x, y, w, h) of the bordered boxes on screen, left to right."""
    boxes = []
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch not in "┌╭":
                continue
            right = next((i for i in range(x + 1, len(row)) if row[i] in "┐╮"), None)
            bottom = next((j for j in range(y + 1, len(rows)) if x < len(rows[j]) and rows[j][x] in "└╰"), None)
            if right is not None and bottom is not None and right - x > 2 and bottom - y > 2:
                boxes.append((x + 1, y + 1, right - x - 1, bottom - y - 1))
    return sorted(boxes)


def view(k):
    """The host state by pane (left to right; one unbordered pane when there are no
    boxes): a dict with `per` (per pane, the sorted placements as (x, y relative to the
    content rect, or None without a border, cols, rows, src w, src h, image w, image h)),
    `ids` (per pane, the host image ids placed), `bottom` (per pane, {image id: lowest
    pane-relative row + 1 of its pieces}), `images` (host image ids held) and `problems`
    (a placement outside every pane or of an unknown image)."""
    rects = panes(k.screen.rows())
    boxed = bool(rects)
    rects = rects or [(0, 0, 10_000, 10_000)]
    snap = {"per": [[] for _ in rects], "ids": [set() for _ in rects], "bottom": [{} for _ in rects],
            "images": set(k.images), "problems": []}
    for (iid, pid), p in sorted(k.placements.items()):
        img = k.images.get(iid)
        if img is None:
            snap["problems"].append(f"placement {(iid, pid)} of a deleted image")
            continue
        n = next((i for i, (x, y, w, h) in enumerate(rects)
                  if x <= p["x"] and p["x"] + p["cols"] <= x + w and y <= p["y"] and p["y"] + p["rows"] <= y + h),
                 None)
        if n is None:
            snap["problems"].append(f"placement {(iid, pid)} at {p['x']},{p['y']} {p['cols']}x{p['rows']} "
                                    f"not inside a pane {rects}")
            continue
        x, y = (p["x"] - rects[n][0], p["y"] - rects[n][1]) if boxed else (None, None)
        snap["per"][n].append((x, y, p["cols"], p["rows"], *p["src"][2:], *img["size"]))
        snap["ids"][n].add(iid)
        if boxed:
            snap["bottom"][n][iid] = max(snap["bottom"][n].get(iid, 0), y + p["rows"])
    snap["per"] = [sorted(pane) for pane in snap["per"]]
    return snap


class Driver:
    def __init__(self, name, term, stop):
        self.name, self.term, self.stop, self.k = name, term, stop, Kitty()

    def pump(self, wait=0.05):
        data = self.term.read(wait)
        if data:
            self.k.feed(data)

    def until(self, check, label, timeout=TIMEOUT):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            got = check()
            if got:
                return got
            self.pump()
        if verbose:
            print(f"--- {self.name} screen", self.k.screen.text(), self.k.dump(), sep="\n")
        raise Failed(f"{self.name}: timed out waiting for {label}")

    def settle(self, quiet=1.5, cap=30):
        end = time.monotonic() + cap
        while time.monotonic() < end:
            data = self.term.read(quiet)
            if not data and not self.term.hup:
                return
            self.k.feed(data)

    def send(self, data):
        self.term.send(data)

    def shows(self, text):
        return text in self.k.screen.text()

    def counts(self):
        """Distinct images placed per pane (a multiplexer may split one placement into
        pieces, e.g. a virtual placement per row)."""
        return [len(ids) for ids in view(self.k)["ids"]]

    def resize(self, cols, rows):
        # a fresh screen (both repaint on SIGWINCH); the graphics state stays, as on a host
        self.k.screen = th.Screen()
        glass.fcntl.ioctl(self.term.master, glass.termios.TIOCSWINSZ, _pack("HHHH", rows, cols, 0, 0))


def scenario(d, tmp, png):
    """Runs the steps; returns [(step, view)]."""
    out = []

    def snap(step):
        d.settle()
        out.append((step, view(d.k)))
        if verbose:
            print(f"--- {d.name} after {step}", d.k.screen.text(), d.k.dump(), sep="\n")

    d.until(lambda: "$ " in d.k.screen.text(), "the pane's prompt")
    d.settle()
    d.send(PREFIX + b"v")
    d.until(lambda: len(panes(d.k.screen.rows())) == 2, "two panes after prefix v")
    d.settle()
    d.send(f"python3 {os.path.join(HERE, 'draw.py')} --scroll 3\r".encode())
    d.until(lambda: d.counts()[-1:] == [7], "the draw pane's 7 images placed")
    d.send(PREFIX + b"h")
    d.settle()
    d.send(f"{KITTEN} icat --transfer-mode=stream --place 30x10@2x2 {png}\r".encode())
    d.until(lambda: d.counts() == [1, 7], "the icat placement in the left pane")
    snap("split")
    d.resize(100, 30)
    d.until(lambda: len(panes(d.k.screen.rows())) == 2 and d.counts()[0] == 1, "the 100x30 repaint")
    snap("resize")
    x, y, w, h = panes(d.k.screen.rows())[1]
    for _ in range(2):
        d.send(f"\x1b[<64;{x + w // 2 + 1};{y + h // 2 + 1}M".encode())
    snap("scroll")
    d.send(PREFIX + b"c")
    d.settle()
    if d.shows("new tab") and d.shows("save"):  # herdr-live's tab name prompt (M13)
        d.send(b"\r")
    d.until(lambda: len(panes(d.k.screen.rows())) == 0, "a new tab with one pane")
    snap("new-tab")
    d.send(PREFIX + b"p")
    d.until(lambda: len(panes(d.k.screen.rows())) == 2, "the first tab back")
    snap("tab-back")
    d.send(PREFIX + b"l")
    d.settle()
    d.send(PREFIX + b"x")
    d.settle()
    if len(panes(d.k.screen.rows())) != 0 or d.counts() != [1]:
        d.send(b"y")  # the confirm modal
    d.until(lambda: len(panes(d.k.screen.rows())) == 0, "one pane after closing the draw pane")
    snap("close")
    return out


def own_checks(name, steps):
    """{step: [problem]} for one multiplexer on its own."""
    by = dict(steps)
    bad = {s: list(v["problems"]) for s, v in steps}
    for s, want in (("split", [1, 7]), ("resize", [1, 7]), ("new-tab", [0]), ("tab-back", [1, 7]), ("close", [1])):
        got = [len(ids) for ids in by[s]["ids"]]
        if got != want:
            bad[s].append(f"{name}: images placed per pane {got}, want {want}")
    if by["tab-back"]["per"] != by["scroll"]["per"]:
        bad["tab-back"].append(f"{name}: after the tab switch {by['tab-back']['per']} != before {by['scroll']['per']}")
    if len(by["scroll"]["bottom"]) == 2 and len(by["resize"]["bottom"]) == 2:
        before, after = by["resize"]["bottom"][1], by["scroll"]["bottom"][1]
        stuck = [i for i in before if i in after and after[i] <= before[i]]
        if stuck or not after:
            bad["scroll"].append(f"{name}: wheel up did not move the draw pane's images down: {before} -> {after}")
    drawn = by["scroll"]["ids"][1] - by["scroll"]["ids"][0] if len(by["scroll"]["ids"]) == 2 else set()
    if drawn & set().union(*by["close"]["ids"]):
        bad["close"].append(f"{name}: draw pane images {sorted(drawn & set().union(*by['close']['ids']))} "
                            "still placed after close")
    if drawn & by["close"]["images"]:
        bad["close"].append(f"{name}: draw pane images {sorted(drawn & by['close']['images'])} still held "
                            "by the host after close")
    return bad


def herdr(tmp, bin_):
    os.makedirs(tmp)
    return glass.herdr(tmp, bin_, 120, 40)  # isolated config, runtime dir and session


def herdr_live(tmp):
    os.makedirs(tmp)
    h = th.Herdr(tmp, 120, 40)  # isolated log, API socket, runtime and state dirs, no onboarding
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


def run(name, launch, tmp, png):
    d = Driver(name, *launch())
    try:
        return scenario(d, tmp, png), d
    finally:
        try:
            d.stop()
        except (OSError, subprocess.SubprocessError):
            pass


def main():
    only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
    tmp = tempfile.mkdtemp(prefix="gfx", dir="/var/tmp")  # short: herdr's socket path
    png = os.path.join(tmp, "icat.png")
    with open(png, "wb") as f:
        f.write(draw.png(200, 100))
    results, failed = {}, False
    try:
        if only != "herdr-live":
            bin_ = subprocess.check_output([os.path.join(LIVE, "bench", "gate", "herdr_ref.sh")], text=True).strip()
            results["herdr"] = run("herdr", lambda: herdr(os.path.join(tmp, "h"), bin_), tmp, png)[0]
        if only != "herdr":
            th.compile_then_start_clock(tmp)
            th.DEADLINE = time.monotonic() + 3600
            th.fail = lambda msg: (_ for _ in ()).throw(Failed(msg))
            results["herdr-live"] = run("herdr-live", lambda: herdr_live(os.path.join(tmp, "l")), tmp, png)[0]
    except Failed as e:
        print(f"FAIL graphics: {e}")
        failed = True
    finally:
        for pg in glass.pgroups | th.pgroups:
            try:
                os.killpg(pg, signal.SIGKILL)
            except OSError:
                pass
        shutil.rmtree(tmp, ignore_errors=True)
    checks = {name: own_checks(name, steps) for name, steps in results.items()}
    for i, step in enumerate(s for s, _ in next(iter(results.values()), [])):
        problems = [p for c in checks.values() for p in c.get(step, [])]
        views = {name: steps[i][1] for name, steps in results.items() if i < len(steps)}
        if len(views) == 2 and views["herdr"]["per"] != views["herdr-live"]["per"]:
            problems.append(f"herdr {views['herdr']['per']} != herdr-live {views['herdr-live']['per']}")
        counts = "; ".join(f"{n} {[len(p) for p in v['per']]} ({[len(ids) for ids in v['ids']]} images)"
                           for n, v in views.items())
        if problems:
            failed = True
            print(f"FAIL {step}: placements per pane {counts}")
            for p in problems:
                print(f"  - {p}")
        else:
            same = " equal to herdr" if len(views) == 2 else f" ({', '.join(views)} only)"
            print(f"PASS {step}{same}: placements per pane {counts}")
    return 1 if failed else 0


if __name__ == "__main__":
    if os.environ.get("HERDR_BROKER_SOCK"):
        print("SKIP: graphics: running inside herdr-live (run it outside, see editing-live.md)")
        sys.exit(0)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    sys.exit(main())
