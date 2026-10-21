"""The FM instrument patches the game's sound program uses, from MAME logs
of its YM2203 writes (tools/mame/sound_log.lua): every distinct patch at key
on, how often, and the notes (F-number, block) it plays.

usage: python3 tools/sound/patches.py analysis/sound/ym_music.txt [...] -> analysis/sound/patches.txt
"""
import collections
import sys

import opn


def scan(paths):
    patches = collections.OrderedDict()
    for path in paths:
        regs = [[0] * 256 for _ in range(2)]
        keyed = [[False] * 3 for _ in range(2)]
        for line in open(path):
            f = line.split()
            if f[0] != "W":
                continue
            chip, reg, val = int(f[2]), int(f[3], 16), int(f[4], 16)
            regs[chip][reg] = val
            if reg == 0x28 and val & 3 < 3:
                ch, on = val & 3, val >> 4 != 0
                if on and not keyed[chip][ch]:
                    p = opn.patch_regs(regs[chip], ch)
                    key = (tuple(tuple(p[b]) for b in sorted(k for k in p if k != 0xB0)), p[0xB0] & 0x3F)
                    e = patches.setdefault(key, {"count": 0, "notes": collections.Counter()})
                    e["count"] += 1
                    fnum = (regs[chip][0xA4 + ch] & 7) << 8 | regs[chip][0xA0 + ch]
                    block = regs[chip][0xA4 + ch] >> 3 & 7
                    e["notes"][(fnum, block)] += 1
                keyed[chip][ch] = on
    return patches


def as_regs(key):
    ops, fbalg = key
    bases = (0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90)
    p = {b: list(v) for b, v in zip(bases, ops)}
    p[0xB0] = fbalg
    return p


def main():
    patches = scan(sys.argv[1:])
    with open("analysis/sound/patches.txt", "w") as o:
        for i, (key, e) in enumerate(patches.items()):
            notes = e["notes"]
            freqs = sorted(opn.freq(f, b) for (f, b) in notes)
            o.write("patch %d: used %d times, %d notes %.0f-%.0f Hz, alg %d fb %d\n" %
                    (i, e["count"], len(notes), freqs[0], freqs[-1], key[1] & 7, key[1] >> 3))
            for b, v in zip((0x30, 0x40, 0x50, 0x60, 0x70, 0x80), key[0]):
                o.write("  %02x: %s\n" % (b, " ".join("%02x" % x for x in v)))
    print("%d patches -> analysis/sound/patches.txt" % len(patches))


if __name__ == "__main__":
    main()
