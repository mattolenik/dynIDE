#!/usr/bin/env python3
"""Run inside a pane: sends terminal queries to its tty, one at a time, each followed
by a DA1 sentinel, and writes each reply hex-escaped to OUT (one `NAME reply` line,
`NAME (none)` when only the sentinel came back within TIMEOUT seconds).

Usage: child_queries.py OUT [TIMEOUT]
"""
import os
import re
import select
import sys
import termios
import time
import tty

QUERIES = [
    ("DA1", b"\x1b[c"),
    ("DA2", b"\x1b[>c"),
    ("DSR5n", b"\x1b[5n"),
    ("DSR6n", b"\x1b[6n"),
    ("XTVERSION", b"\x1b[>0q"),
    ("kitty", b"\x1b[?u"),
    ("DECRQM2004", b"\x1b[?2004$p"),
    ("OSC11", b"\x1b]11;?\x1b\\"),
    ("XTGETTCAP_TN", b"\x1bP+q544e\x1b\\"),
]
SENTINEL = b"\x1b[c"
DA1 = re.compile(rb"\x1b\[\?[0-9;]*c")


def escape(b):
    return "".join(c if " " <= c <= "~" and c != "\\" else f"\\x{ord(c):02x}"
                   for c in b.decode("latin-1"))


def ask(fd, query, timeout):
    """The bytes before the sentinel's DA1 reply (DA1 itself: the first reply)."""
    os.write(fd, query + SENTINEL)
    need = 2 if query == SENTINEL else 1
    buf, end = b"", time.monotonic() + timeout
    while len(DA1.findall(buf)) < need and time.monotonic() < end:
        if select.select([fd], [], [], 0.1)[0]:
            buf += os.read(fd, 4096)
    replies = list(DA1.finditer(buf))
    if len(replies) < need:
        return None  # the sentinel never came: a timeout
    sentinel = replies[need - 1]
    return buf[:sentinel.start()]


def main():
    out, timeout = sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else 10.0
    fd = os.open("/dev/tty", os.O_RDWR)
    saved = termios.tcgetattr(fd)
    lines = []
    try:
        tty.setraw(fd)
        for name, q in QUERIES:
            got = ask(fd, q, timeout)
            lines.append(f"{name} {'(timeout)' if got is None else escape(got) or '(none)'}")
    finally:
        termios.tcsetattr(fd, termios.TCSAFLUSH, saved)
    with open(out + ".tmp", "w") as f:
        f.write("\n".join(lines) + "\n")
    os.rename(out + ".tmp", out)


if __name__ == "__main__":
    main()
