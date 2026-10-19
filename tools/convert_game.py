"""Convert the Black Tiger graphics ROMs for the translated game (src/amiga_main.s).

usage: python3 tools/convert_game.py ROMS OUTDIR

Writes into OUTDIR:
  z80fixed.bin   main CPU fixed ROM ($0000-$7FFF)
  z80banks.bin   main CPU banked ROM, 16 x 16K
  bgtiles.bin    2048 background tiles, 4 bitplanes, plane-major:
                 4 planes x 16 rows x 1 word = 128 bytes per tile (plane p = pen bit p)
  chars.bin      2048 text characters as sprite data: 8 rows x (plane A byte,
                 plane B byte). Arcade pen 3 is transparent, so pen p is stored
                 as sprite colour (p + 1) & 3.
  charblank.bin  2048 bytes: 1 if the character is fully transparent
"""
import os
import sys

import bt_rom


def main():
    roms, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    r = bt_rom.load_roms(roms)
    open(os.path.join(out, "z80fixed.bin"), "wb").write(bytes(r["maincpu"][:0x8000]))
    open(os.path.join(out, "z80banks.bin"), "wb").write(bytes(r["maincpu"][0x10000:0x50000]))

    tiles = bt_rom.decode_16x16(r["tiles"])
    with open(os.path.join(out, "bgtiles.bin"), "wb") as f:
        for px in tiles:
            for plane in range(4):
                for y in range(16):
                    w = 0
                    for x in range(16):
                        w = w << 1 | (px[y * 16 + x] >> plane & 1)
                    f.write(w.to_bytes(2, "big"))

    chars = bt_rom.decode_chars(r["chars"])
    with open(os.path.join(out, "chars.bin"), "wb") as f, \
            open(os.path.join(out, "charblank.bin"), "wb") as fb:
        for px in chars:
            for y in range(8):
                a = b = 0
                for x in range(8):
                    c = (px[y * 8 + x] + 1) & 3
                    a = a << 1 | (c & 1)
                    b = b << 1 | (c >> 1)
                f.write(bytes((a, b)))
            fb.write(bytes((1 if all(p == 3 for p in px) else 0,)))
    print("graphics: %d tiles, %d characters" % (len(tiles), len(chars)))


if __name__ == "__main__":
    main()
