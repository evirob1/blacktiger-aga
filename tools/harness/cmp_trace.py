"""Line up a MAME instruction trace (with totalcycles) and the harness boundary
trace, and report where the cycle offset between them changes.

usage: cmp_trace.py mame_trace.txt build/harness_trace.txt build/harness.lst
"""
import re
import sys

# hand-written scheduler, plus the slot helper it calls ($013E) which we don't run
EXCLUDE = [(0x00B3, 0x00F6), (0x0116, 0x0135), (0x013E, 0x014C)]


def main():
    mame = []
    for line in open(sys.argv[1]):
        m = re.match(r"(\d+) ([0-9A-F]{4}): (.*)", line)
        if m:
            a = int(m.group(2), 16)
            if any(lo <= a < hi for lo, hi in EXCLUDE):
                continue
            if mame and mame[-1][1] == a and m.group(3).startswith(("ldir", "lddr")):
                continue        # repeated block-move iterations: one instruction for us
            mame.append((int(m.group(1)), a, m.group(3)))
    syms = {}
    for line in open(sys.argv[3]):
        m = re.match(r"([zb][0-9a-f]*_[0-9a-f]{4})\s+A:([0-9A-F]{8})", line)
        if m:
            syms[int(m.group(2), 16)] = int(m.group(1).split("_")[1], 16)
    ours = []
    for line in open(sys.argv[2]):
        t, pc = line.split()
        a = syms.get(int(pc, 16))
        if a is not None and not any(lo <= a < hi for lo, hi in EXCLUDE):
            ours.append((int(t), a))
    # align on the first common address
    i = j = 0
    while i < len(mame) and mame[i][1] != ours[0][1]:
        i += 1
    prev = None
    shown = 0
    while i < len(mame) and j < len(ours):
        tm, am, txt = mame[i]
        to, ao = ours[j]
        if am != ao:
            print("paths differ: MAME %04x (%s) at %d, ours %04x at %d" % (am, txt, tm, ao, to))
            return
        off = tm - to
        if prev is not None and off != prev:
            pt = mame[i - 1]
            print("offset %+d -> %+d after %04x %s (MAME %d)" % (prev, off, pt[1], pt[2], pt[0]))
            shown += 1
            if shown > 30:
                return
        prev = off
        i += 1
        j += 1
    print("compared %d instructions" % j)


if __name__ == "__main__":
    main()
