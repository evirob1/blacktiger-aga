"""Render graphics sheets and a background map from a MAME memory dump.

usage: python3 tools/preview.py ROMS OUTDIR [DUMPPREFIX]
DUMPPREFIX points at .bg/.pal/.palx files written by tools/mame/capture.lua.
"""
import sys
from PIL import Image

import bt_rom


def sheet(tiles, size, cols, pal_fn):
    rows = (len(tiles) + cols - 1) // cols
    im = Image.new("RGB", (cols * size, rows * size))
    px = im.load()
    for i, t in enumerate(tiles):
        ox, oy = (i % cols) * size, (i // cols) * size
        for p, v in enumerate(t):
            px[ox + p % size, oy + p // size] = pal_fn(v)
    return im


def grey(levels):
    return lambda v: (v * 255 // (levels - 1),) * 3


def render_map(bg, pal, tiles, layout8x4):
    w, h = (128, 64) if layout8x4 else (64, 128)
    im = Image.new("RGB", (w * 16, h * 16))
    px = im.load()
    for row in range(h):
        for col in range(w):
            t = bt_rom.bg_offset(col, row, layout8x4)
            attr = bg[2 * t + 1]
            code = bg[2 * t] | (attr & 7) << 8
            color = (attr & 0x78) >> 3
            flip = attr & 0x80
            gfx = tiles[code]
            for y in range(16):
                for x in range(16):
                    v = gfx[y * 16 + (15 - x if flip else x)]
                    px[col * 16 + x, row * 16 + y] = pal[color * 16 + v]
    return im


def main():
    roms, out = sys.argv[1], sys.argv[2]
    r = bt_rom.load_roms(roms)
    chars = bt_rom.decode_chars(r["chars"])
    tiles = bt_rom.decode_16x16(r["tiles"])
    sprites = bt_rom.decode_16x16(r["sprites"])
    print("chars %d  tiles %d  sprites %d" % (len(chars), len(tiles), len(sprites)))
    sheet(chars, 8, 64, grey(4)).save(out + "/chars.png")
    sheet(tiles, 16, 64, grey(16)).save(out + "/tiles.png")
    sheet(sprites, 16, 64, grey(16)).save(out + "/sprites.png")
    if len(sys.argv) > 3:
        p = sys.argv[3]
        bg = open(p + ".bg", "rb").read()
        pal = bt_rom.decode_palette(open(p + ".pal", "rb").read(), open(p + ".palx", "rb").read())
        for lay in (0, 1):
            render_map(bg, pal, tiles, lay).save(out + "/map_layout%d.png" % lay)


if __name__ == "__main__":
    main()
