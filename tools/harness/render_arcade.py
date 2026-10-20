"""Render the arcade picture as MAME draws it (backdrop, background, sprites,
text) from an amiga_sim memory dump: the Z80's video RAM and palette RAM,
and the view position and sprite list the Amiga display last drew. A
reference for tools/harness/render_frame.py; with a third argument, compares
the two and writes a difference image.

The background is drawn in one layer (the "front" pens over sprites aren't
emulated on the Amiga yet, so they aren't here either).

usage: python3 tools/harness/render_arcade.py build/amiga_mem_N.bin ref.png [amiga.png diff.png]
"""
import os
import re
import sys
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import bt_rom  # noqa: E402

BASE = 0x10000
W, H = 256, 224


def symbols():
    out = {}
    for line in open("build/game/game.lst"):
        m = re.match(r"(\S+)\s+[AE]:([0-9A-F]{8})", line)
        if m:
            out.setdefault(m.group(1), int(m.group(2), 16))
    return out


def main():
    mem = open(sys.argv[1], "rb").read()
    s = symbols()
    z80 = BASE + s["z80mem"]
    zb = lambda a: mem[z80 + (a ^ 0x8000)]
    pv = BASE + s["pvars"]
    pvb = lambda name, i=0: mem[pv + s[name] + i]
    pvw = lambda name: (mem[pv + s[name]] << 8 | mem[pv + s[name] + 1])
    bgram = BASE + s["bgram"]
    bgbank = mem[BASE + s["rt_vars"] + 1]
    rom = bt_rom.load_roms("roms/blktiger.zip")
    tiles = bt_rom.decode_16x16(rom["tiles"])
    sprites = bt_rom.decode_16x16(rom["sprites"])
    chars = bt_rom.decode_chars(rom["chars"])

    def rgb(i):
        lo, hi = zb(0xD800 + i), zb(0xDC00 + i)
        return ((lo >> 4) * 17, (lo & 15) * 17, (hi & 15) * 17)

    io = lambda p: pvb("pv_iod", p)
    layout = io(0x0E) & 1
    mw, mh = (2048, 1024) if layout else (1024, 2048)
    # the view position the display last drew with (the scroll registers may
    # have moved on since)
    sx0 = pvw("pv_vx") & (mw - 1)
    sy0 = pvw("pv_vy") & (mh - 1)
    img = Image.new("RGB", (W, H), rgb(1023))
    px = img.load()
    bgon, objon, chon = not io(0x0C) & 2, not io(0x0C) & 4, not io(4) & 0x80

    if bgon:
        for y in range(H):
            my = (sy0 + y) & (mh - 1)
            r = my >> 4
            for x in range(W):
                mx = (sx0 + x) & (mw - 1)
                c = mx >> 4
                if layout:
                    off = ((c & 15) + ((c & 0x70) << 4)) * 2 + (r & 15) * 32 + ((r & 0x30) << 8)
                else:
                    off = ((c & 15) + ((c & 0x30) << 4)) * 2 + (r & 15) * 32 + ((r & 0x70) << 7)
                if off >> 12 == bgbank:
                    code, attr = zb(0xC000 + (off & 0xFFF)), zb(0xC001 + (off & 0xFFF))
                else:
                    code, attr = mem[bgram + off], mem[bgram + off + 1]
                t = tiles[code | (attr & 7) << 8]
                tx, ty = mx & 15, my & 15
                if attr & 0x80:
                    tx = 15 - tx
                pen = t[ty * 16 + tx]
                if pen != 15:
                    px[x, y] = rgb(((attr >> 3) & 15) * 16 + pen)

    if objon:
        spr = [pvb("pv_sprsnap", i) for i in range(512)]
        for offs in range(127 * 4, -1, -4):
            attr = spr[offs + 1]
            sy = spr[offs + 2]
            sx = spr[offs + 3] - ((attr & 0x10) << 4)
            code = spr[offs] | (attr & 0xE0) << 3
            col = attr & 7
            t = sprites[code]
            for yy in range(16):
                y = sy - 16 + yy
                if not 0 <= y < H:
                    continue
                for xx in range(16):
                    x = sx + xx
                    if not 0 <= x < W:
                        continue
                    pen = t[yy * 16 + (15 - xx if attr & 8 else xx)]
                    if pen != 15:
                        px[x, y] = rgb(0x200 + col * 16 + pen)

    if chon:
        for row in range(2, 30):
            for colm in range(32):
                cell = row * 32 + colm
                attr = zb(0xD400 + cell)
                ch = chars[zb(0xD000 + cell) | (attr & 0xE0) << 3]
                for yy in range(8):
                    for xx in range(8):
                        pen = ch[yy * 8 + xx]
                        if pen != 3:
                            px[colm * 8 + xx, (row - 2) * 8 + yy] = rgb(0x300 + (attr & 0x1F) * 4 + pen)
    img.save(sys.argv[2])

    if len(sys.argv) > 4:
        a = Image.open(sys.argv[3]).convert("RGB")
        diff = Image.new("RGB", (W, H))
        d, pa, pb = diff.load(), a.load(), img.load()
        bad = 0
        for y in range(H):
            for x in range(W):
                if pa[x, y] != pb[x, y]:
                    bad += 1
                    d[x, y] = (255, 0, 0)
                else:
                    d[x, y] = tuple(v // 3 for v in pb[x, y])
        diff.save(sys.argv[4])
        print("%s: view x %d y %d, %d of %d pixels differ" % (sys.argv[1], sx0, sy0, bad, W * H))


if __name__ == "__main__":
    main()
