"""Render a full Amiga frame from an amiga_sim memory dump: follows the active
copper list (palette, bitplane pointers, fine scroll, modulo changes, sprite
pointers, colour changes per line) and draws bitplanes + the 64-pixel sprites
(text: sprites 2n / 2n+1 over the same 64 pixels, colours 240+ / 224+),
for the 256 x 224 display window.

usage: python3 tools/harness/render_frame.py build/amiga_mem.bin out.png
"""
import os
import re
import sys
from PIL import Image

BASE = int(os.environ.get("BT_BASE", "10000"), 16)   # amiga_sim BT_FASTMODE: 800000
H, W = 224, 256


def sym(name):
    for line in open("build/game/game.lst"):
        m = re.match(r"(\S+)\s+[AE]:([0-9A-F]{8})", line)
        if m and m.group(1) == name:
            return int(m.group(2), 16)
    raise KeyError(name)


def main():
    global DISP_Y0
    try:
        DISP_Y0 = sym("DISP_Y0")
    except KeyError:
        DISP_Y0 = 0x3c
    mem = open(sys.argv[1], "rb").read()
    w16 = lambda a: mem[a] << 8 | mem[a + 1]
    cop = int.from_bytes(mem[BASE + sym("coplist_ptr"):][:4], "big")
    regs = {}
    pal = [0] * 256
    bank = 0
    events = {}          # line -> list of (reg, value) applied at the start of the line
    line = 0
    pos = cop
    past255 = False
    for _ in range(4000):
        a, b = w16(pos), w16(pos + 2)
        pos += 4
        if a == 0xffff and b == 0xfffe:
            break
        if a & 1:                                    # WAIT
            v = a >> 8
            if v == 0xff:
                past255 = True
                continue
            line = v + (256 if past255 else 0)
            continue
        events.setdefault(line, []).append((a, b))
    # apply events in order
    state = {}
    ptr = [0] * 8
    sprptr = [0] * 8
    img = Image.new("RGB", (W, H))
    px = img.load()

    def apply(reg, val):
        nonlocal bank
        state[reg] = val
        if reg == 0x106:
            bank = val >> 13
        elif 0x180 <= reg < 0x1c0:
            pal[bank * 32 + (reg - 0x180) // 2] = val
        elif 0xe0 <= reg < 0x100:
            i = (reg - 0xe0) // 4
            if reg & 2:
                ptr[i] = (ptr[i] & 0xffff0000) | val
            else:
                ptr[i] = (ptr[i] & 0xffff) | val << 16
        elif 0x120 <= reg < 0x140:
            i = (reg - 0x120) // 4
            if reg & 2:
                sprptr[i] = (sprptr[i] & 0xffff0000) | val
            else:
                sprptr[i] = (sprptr[i] & 0xffff) | val << 16

    for l in sorted(k for k in events if k < DISP_Y0):
        for r, v in events[l]:
            apply(r, v)
    nplanes = 8 if state.get(0x100, 0) & 0x10 else (state.get(0x100, 0) >> 12) & 7
    con1 = state.get(0x102, 0)
    delay1 = (con1 & 15) | ((con1 >> 10) & 3) << 4     # PF1H in lowres pixels (bits 3-0, 11-10)
    fetchb = 36
    for y in range(H):
        l = DISP_Y0 + y
        for r, v in events.get(l, []):
            apply(r, v)
        mod = (state.get(0x108, 0) ^ 0x8000) - 0x8000
        rgb = [((c >> 8 & 15) * 17, (c >> 4 & 15) * 17, (c & 15) * 17) for c in pal]
        for x in range(W):
            # window pixel x shows fetched pixel (32 - delay + x)
            fx = 32 - delay1 + x
            v = 0
            if nplanes:
                for p in range(8):
                    byte = mem[ptr[p] + (fx >> 3)]
                    v |= (byte >> (7 - (fx & 7)) & 1) << p
            c = rgb[v]
            s = x // 64
            bit = 7 - (x & 7)
            for k, cbase in ((2 * s, 240), (2 * s + 1, 224)):   # even sprite in front
                sp = sprptr[k] + 16 + y * 16
                sa = mem[sp + (x & 63) // 8] >> bit & 1
                sb = mem[sp + 8 + (x & 63) // 8] >> bit & 1
                if sa | sb:
                    c = rgb[cbase + s * 4 + (sa | sb << 1)]
                    break
            px[x, y] = c
        for p in range(8):
            ptr[p] += fetchb + mod
    img.save(sys.argv[2])


if __name__ == "__main__":
    main()
