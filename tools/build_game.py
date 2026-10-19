"""Build the Black Tiger AGA game disk from your own MAME ROM set.

usage:  python tools/build_game.py [--roms roms/blktiger.zip]
Output: build/blacktiger.adf

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

BSS = 420000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--roms", default=os.path.join(ROOT, "roms", "blktiger.zip"))
    a = ap.parse_args()
    out = os.path.join(ROOT, "build", "game")
    os.makedirs(out, exist_ok=True)

    sys.argv = ["convert_game", a.roms, out]
    convert_game.main()

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
    build.assemble(os.path.join(ROOT, "src", "amiga_main.s"), payload,
                   incdir=out, extra=["-I" + os.path.join(ROOT, "src")])
    mkadf.build(boot, payload, BSS, os.path.join(ROOT, "build", "blacktiger.adf"))


if __name__ == "__main__":
    main()
