# Independent encoder for golden vectors (cross-check for the Elixir/Rust encoders).
import json, struct, sys
FLAGS = ["bold","italic","faint","blink","inverse","invisible","strikethrough","overline"]
UL = ["none","single","double","curly","dotted","dashed"]
def col(c):
    if c == "default": return 0
    if "palette" in c: return (1<<24) | c["palette"]
    r,g,b = c["rgb"]; return (2<<24)|(r<<16)|(g<<8)|b
def cell(glyph="", **kw):
    c = {"glyph": glyph}; c.update(kw); return c
def full(c):
    d = {"glyph":"","fg":"default","bg":"default","ul":"default","attrs":[],"underline":"none","width":1,"link":0}
    d.update(c); return d
def enc(cells):
    recs = b""; tr = b""
    for c in map(full, cells):
        g = c["glyph"].encode()
        if len(g) <= 12: gb = g + b"\0"*(12-len(g))
        else:
            gb = bytes([0xFF,0,0,0]) + struct.pack("<II", len(tr), len(g)); tr += g
        attrs = sum(1<<i for i,f in enumerate(FLAGS) if f in c["attrs"]) | (UL.index(c["underline"])<<8)
        recs += gb + struct.pack("<IIIHBBI", col(c["fg"]), col(c["bg"]), col(c["ul"]), attrs, c["width"], 0, c["link"])
    return recs + tr + struct.pack("<I", len(tr))
R = lambda r,g,b: {"rgb":[r,g,b]}
P = lambda i: {"palette":i}
V = [
 ("empty_row", []),
 ("ascii_padded", [cell("h"), cell("i"), cell(" "), cell(), cell(), cell()]),
 ("blank_cells", [cell(), cell(bg=P(4)), cell(bg=R(0x10,0x20,0x30))]),
 ("wide_cjk", [cell("中", width=2), cell(width=0), cell("文", width=2), cell(width=0), cell("a")]),
 ("wide_spacer_head", [cell("x"), cell()]),
 ("combining_inline", [cell("é"), cell("x́⃝⃝⃝")]),
 ("combining_overflow", [cell("a" + "́"*6), cell("b")]),
 ("emoji_zwj_inline", [cell("\U0001F468‍\U0001F4BB", width=2), cell(width=0)]),
 ("emoji_zwj_overflow_twice", [cell("\U0001F468‍\U0001F469‍\U0001F467‍\U0001F466", width=2), cell(width=0),
                               cell("z"), cell("❤️‍\U0001F525", width=2), cell(width=0)]),
 ("emoji_flag_skin_vs16", [cell("\U0001F1EF\U0001F1F5", width=2), cell(width=0), cell("\U0001F44D\U0001F3FD", width=2), cell(width=0), cell("❤️", width=2), cell(width=0)]),
 ("palette_colors", [cell("a", fg=P(0), bg=P(255)), cell("b", fg=P(1), bg=P(16)), cell("c", fg=P(231), ul=P(9))]),
 ("rgb_colors", [cell("a", fg=R(255,0,0), bg=R(0,255,0)), cell("b", fg=R(1,2,3), ul=R(0,0,255)), cell("c", fg=R(255,255,255), bg=R(0,0,0))]),
 ("attr_bits", [cell("x", attrs=[f]) for f in FLAGS] + [cell("A", attrs=list(FLAGS), underline="curly")]),
 ("underline_styles", [cell("u", underline=u) for u in UL]),
 ("link_ids", [cell("h", link=1), cell("t", link=1), cell(" "), cell("x", link=0xFFFFFFFF), cell("y", link=0x01020304)]),
]
json.dump({"record_size": 32, "vectors": [{"name": n, "cells": [full(c) for c in cs], "hex": enc(cs).hex()} for n, cs in V]},
          sys.stdout, ensure_ascii=False, indent=1)
print()
