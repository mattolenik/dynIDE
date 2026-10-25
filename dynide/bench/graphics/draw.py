#!/usr/bin/env python3
"""An image-heavy TUI child for the M10 graphics checks (stdlib only).

Writes kitty graphics APCs itself (q=2, so the terminal sends no replies):
six images (t=d: RGB f=24, RGBA f=32 and one PNG f=100) and shown as a
3x2 grid of 10x4-cell placements with explicit ids p=11..16, plus image 7 shown through a
unicode-placeholder virtual placement (U=1, 4x2 cells of U+10EEEE, foreground colour 7 =
the image id, row/column diacritics). Runs on the primary screen; on SIGWINCH it clears,
re-transmits and redraws. Then it waits for a signal.

Usage: draw.py [--scroll N] [--animate]
  --scroll N  after drawing, print lines under the grid until the screen has scrolled N
              rows (the top grid row then sits partly above the viewport)
  --animate   keep replacing image 1 with new pixels (every 50 ms) instead of waiting
"""
import base64
import os
import signal
import struct
import sys
import time
import zlib

GRID = [(1, 24, 40, 20), (2, 32, 30, 30), (3, 100, 50, 25),  # (id, f, width, height)
        (4, 24, 20, 40), (5, 32, 60, 20), (6, 24, 33, 17)]
VIRTUAL = (7, 24, 20, 20)
BOX_COLS, BOX_ROWS = 10, 4
BELOW = 14  # first row under the grid and the placeholder
DIACRITICS = "̅̍̎̐"  # row/column 0..3 (kitty's rowcolumn-diacritics table)


def pixels(w, h, channels, seed=0):
    return bytes((x * 7 + y * 3 + c * 50 + seed) % 256
                 for y in range(h) for x in range(w) for c in range(channels))


def png(w, h, seed=0):
    """An RGB PNG (stdlib zlib)."""
    raw = pixels(w, h, 3, seed)
    rows = b"".join(b"\0" + raw[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def apc(control, payload=b""):
    return b"\x1b_G" + control.encode() + (b";" + payload if payload else b"") + b"\x1b\\"


def transmit(image_id, fmt, w, h, seed=0):
    data = png(w, h, seed) if fmt == 100 else pixels(w, h, fmt // 8, seed)
    b64 = base64.b64encode(data)
    chunks = [b64[i:i + 4096] for i in range(0, len(b64), 4096)]
    out = b""
    for n, c in enumerate(chunks):
        more = int(n < len(chunks) - 1)
        out += apc(f"a=t,t=d,f={fmt},s={w},v={h},i={image_id},q=2,m={more}" if n == 0 else f"m={more}", c)
    return out


def place(image_id, x, y):
    return f"\x1b[{y + 1};{x + 1}H".encode() + apc(f"a=p,i={image_id},p={10 + image_id},"
                                                    f"c={BOX_COLS},r={BOX_ROWS},C=1,q=2")


def draw(scroll):
    # transmitted after the clear: a terminal may free unplaced images on ED 2
    out = b"\x1b[2J\x1b[H" + b"".join(transmit(*img) for img in GRID + [VIRTUAL])
    for n, (image_id, *_rest) in enumerate(GRID):
        out += place(image_id, 1 + (n % 3) * (BOX_COLS + 2), 1 + (n // 3) * (BOX_ROWS + 1))
    vid = VIRTUAL[0]
    out += apc(f"a=p,U=1,i={vid},p={10 + vid},c=4,r=2,q=2")
    for r in range(2):
        cells = "".join("\U0010eeee" + DIACRITICS[r] + DIACRITICS[c] for c in range(4))
        out += f"\x1b[{12 + r};2H\x1b[38;5;{vid}m{cells}\x1b[39m".encode()
    out += f"\x1b[{BELOW + 1};1Hdraw.py grid".encode()
    if scroll:
        rows = os.get_terminal_size(1).lines
        out += b"".join(f"\r\nscroll {k}".encode() for k in range(max(rows - 1 - BELOW + scroll, 0)))
    os.write(1, out)


def main():
    args = sys.argv[1:]
    scroll = int(args[args.index("--scroll") + 1]) if "--scroll" in args else 0
    draw(scroll)
    signal.signal(signal.SIGWINCH, lambda *_: draw(scroll))
    if "--animate" in args:
        seed = 0
        while True:
            seed += 1
            image_id, fmt, w, h = GRID[0]
            # a new transmission of an id drops its placements: place it again
            os.write(1, b"\x1b7" + transmit(image_id, fmt, w, h, seed) + place(image_id, 1, 1) + b"\x1b8")
            time.sleep(0.05)
    while True:
        signal.pause()


if __name__ == "__main__":
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    main()
