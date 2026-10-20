"""Build the Black Tiger AGA game disk from your own MAME ROM set.

usage:  python tools/build_game.py [--roms roms/blktiger.zip]
Output: build/blacktiger.adf (60 Hz; --pal for 50 Hz)

Needs Python 3 and vasmm68k_mot (on the PATH, or VASM=path).
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import build  # noqa: E402  (vasm helper)
import convert_game  # noqa: E402
import mkadf  # noqa: E402
from z80 import codemap, translate  # noqa: E402
import bt_rom  # noqa: E402
import lzpack  # noqa: E402

PACKED = ["z80banks", "bgtiles", "chars", "sprites"]   # unpacked at boot


def listing_symbol(lst, name):
    for line in open(lst):
        f = line.split()
        if len(f) >= 2 and f[0] == name and f[1][:2] in ("A:", "E:"):
            return int(f[1][2:], 16)
    raise KeyError(name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--roms", default=os.path.join(ROOT, "roms", "blktiger.zip"))
    ap.add_argument("--pal", action="store_true",
                    help="50 Hz display (default: 60 Hz like the arcade, NTSC timing)")
    a = ap.parse_args()
    out = os.path.join(ROOT, "build", "game")
    os.makedirs(out, exist_ok=True)

    sys.argv = ["convert_game", a.roms, out]
    convert_game.main()
    for name in PACKED:
        data = open(os.path.join(out, name + ".bin"), "rb").read()
        packed = lzpack.pack(data)
        open(os.path.join(out, name + ".lz"), "wb").write(packed)
        print("%s: %d -> %d bytes" % (name, len(data), len(packed)))

    rom = bt_rom.load_roms(a.roms)["maincpu"]
    entries = os.path.join(ROOT, "data", "code_entries.txt")
    cm = codemap.build(rom, entries)
    sites = []
    for line in open(os.path.join(ROOT, "data", "bank_reads.txt")):
        f = line.split()
        if f and not line.startswith("#"):
            sites.append((None if f[0] == "ff" else int(f[0], 16), int(f[1], 16)))
    tr = translate.Translator(rom, cm, os.path.join(out, "game.s"), False, sites)
    tr.run()
    problems = sorted(set(p for p in tr.problems if not p.startswith("note:")))
    print("translated %d Z80 instructions, %d problems" % (len(cm.insns), len(problems)))
    for p in problems:
        print("  " + p)

    boot = os.path.join(ROOT, "build", "boot.bin")
    build.assemble(os.path.join(ROOT, "src", "boot.s"), boot)
    payload = os.path.join(out, "game.bin")
    lst = os.path.join(out, "game.lst")
    build.assemble(os.path.join(ROOT, "src", "amiga_main.s"), payload,
                   incdir=out, extra=["-I" + os.path.join(ROOT, "src"), "-L", lst] + (["-DPAL=1"] if a.pal else []))
    at = listing_symbol(lst, "bss_size")
    bss = int.from_bytes(open(payload, "rb").read()[at:at + 4], "big")
    mkadf.build(boot, payload, bss, os.path.join(ROOT, "build", "blacktiger.adf"))


if __name__ == "__main__":
    main()
