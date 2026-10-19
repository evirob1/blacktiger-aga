"""Render the 256x224 view at (x,y) from converted level data - reference for emulator tests.

usage: python3 tools/render_ref.py LEVELDIR X Y out.png
"""
import struct
import sys
from PIL import Image


def main():
    d, x0, y0, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    info = {}
    for line in open(d + "/level.i"):
        f = line.split()
        if len(f) == 3 and f[1] == "equ":
            info[f[0]] = int(f[2])
    map_w = info["MAP_W"]
    pal = [struct.unpack(">I", c)[0] for c in iter(lambda f=open(d + "/level.pal", "rb"): f.read(4), b"")]
    tiles = open(d + "/level.tiles", "rb").read()
    mp = open(d + "/level.map", "rb").read()
    im = Image.new("RGB", (256, 224))
    px = im.load()
    for y in range(224):
        for x in range(256):
            mx, my = x0 + x, y0 + y
            t = struct.unpack(">H", mp[2 * ((my >> 4) * map_w + (mx >> 4)):][:2])[0]
            v = 0
            for p in range(8):
                w = struct.unpack(">H", tiles[t * 256 + p * 32 + (my & 15) * 2:][:2])[0]
                v |= (w >> (15 - (mx & 15)) & 1) << p
            c = pal[v]
            px[x, y] = (c >> 16 & 255, c >> 8 & 255, c & 255)
    im.save(out)


if __name__ == "__main__":
    main()
