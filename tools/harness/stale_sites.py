"""Add the Z80 instructions behind the harness's STALE lines to data/bank_reads.txt.

usage: build/harness ... | python3 tools/harness/stale_sites.py
(needs build/harness.lst from tools/harness/run.sh)
"""
import bisect
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def main():
    syms = {}
    for line in open(os.path.join(ROOT, "build", "harness.lst")):
        m = re.match(r"([zb][0-9a-f]*_[0-9a-f]{4})\s+A:([0-9A-F]{8})", line)
        if m:
            syms[int(m.group(2), 16)] = m.group(1)
    srt = sorted(syms)
    path = os.path.join(ROOT, "data", "bank_reads.txt")
    lines = open(path).read().splitlines()
    have = {tuple(l.split()[:2]) for l in lines if l and not l.startswith("#")}
    added = 0
    for line in sys.stdin:
        sys.stdout.write(line)
        if not line.startswith("STALE "):
            continue
        a = int(line.split()[1], 16)
        lab = syms[srt[bisect.bisect_right(srt, a) - 1]]
        bank, addr = lab.split("_")
        key = ("ff" if bank == "z" else "%02x" % int(bank[1:], 16), addr)
        if key not in have:
            have.add(key)
            lines.append("%s %s  (found by the harness)" % key)
            added += 1
    open(path, "w").write("\n".join(lines) + "\n")
    print("added %d sites to data/bank_reads.txt" % added)


if __name__ == "__main__":
    main()
