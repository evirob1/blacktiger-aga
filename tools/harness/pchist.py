"""Sum a BT_PCHIST profile (tools/harness/amiga_sim.c) by the labels of the
assembler listing: the routines (and loops) the time went to.

usage: python3 tools/harness/pchist.py hist.txt build/game/game.lst [top]
"""
import bisect
import re
import sys


def labels(lst):
    """(address, name) of the labels in the listing's symbol table, in order."""
    out = {}
    for line in open(lst, errors="replace"):
        m = re.match(r"^([A-Za-z_][\w]*)\s+A:([0-9A-F]{8})$", line.rstrip())
        if m:
            out.setdefault(int(m.group(2), 16), m.group(1))
    return sorted(out.items())


def main():
    hist, lst = sys.argv[1], sys.argv[2]
    top = int(sys.argv[3]) if len(sys.argv) > 3 else 40
    labs = labels(lst)
    addrs = [a for a, _ in labs]
    sums, total = {}, 0
    for line in open(hist):
        o, c = line.split()
        o, c = int(o, 16), int(c)
        total += c
        i = bisect.bisect_right(addrs, o) - 1
        name = labs[i][1] if i >= 0 else "?"
        sums[name] = sums.get(name, 0) + c
    for name, c in sorted(sums.items(), key=lambda x: -x[1])[:top]:
        print("%6.2f%%  %s" % (100 * c / total, name))


if __name__ == "__main__":
    main()
