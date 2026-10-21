"""Unpack a WinUAE save state (.uss) of the A1200 game for tools/harness/amiga_sim
(BT_RESUME) and the render / analysis scripts: chip RAM, fast RAM ($200000 on),
the CPU registers, and where the program was loaded (found from the red
screen's title text, bad_title, using the listing of the same build).

usage: python3 tools/harness/uss.py state.uss prefix [build/game/game.lst]
  -> prefix_chip.bin, prefix_fast.bin, prefix_cpu.txt; prints BT_BASE
"""
import re
import struct
import sys
import zlib

FAST = 0x200000


def chunks(path):
    """name -> [(flags, body)]: 4-byte name, length (header included), flags."""
    d = open(path, "rb").read()
    out, p = {}, 0
    while p + 12 <= len(d):
        name = d[p:p + 4]
        ln, fl = struct.unpack(">II", d[p + 4:p + 12])
        if not re.match(rb"[A-Z0-9 ]{4}$", name) or ln < 12 or p + ln > len(d):
            p += 1
            continue
        out.setdefault(name.decode(), []).append((fl, d[p + 12:p + ln]))
        p += ln
    return out


def memory(ch, name):
    if name not in ch:
        return b""
    fl, b = ch[name][0]
    return zlib.decompress(b[4:]) if fl & 1 else b


def cpu(ch):
    """D0-D7, A0-A6, PC, SR, USP, ISP, MSP, VBR (WinUAE's CPU chunk)."""
    b = ch["CPU "][0][1]
    r = list(struct.unpack(">15I", b[8:68]))
    pc, = struct.unpack(">I", b[68:72])
    _irc, _ir, usp, isp, sr = struct.unpack(">HHIIH", b[72:86])
    _flags, _dfc, _sfc, vbr, _caar, _cacr, msp = struct.unpack(">7I", b[86:114])
    return r + [pc, sr, usp, isp, msp, vbr]


def main():
    path, prefix = sys.argv[1], sys.argv[2]
    lst = sys.argv[3] if len(sys.argv) > 3 else "build/game/game.lst"
    ch = chunks(path)
    chip, fast = memory(ch, "CRAM"), memory(ch, "FRAM")
    open(prefix + "_chip.bin", "wb").write(chip)
    open(prefix + "_fast.bin", "wb").write(fast)
    open(prefix + "_cpu.txt", "w").write(" ".join("%x" % v for v in cpu(ch)) + "\n")
    title = None
    for line in open(lst):
        m = re.match(r"bad_title\s+A:([0-9A-F]{8})", line)
        if m:
            title = int(m.group(1), 16)
    for start, mem in ((FAST, fast), (0, chip)):
        i = mem.find(b"UNKNOWN Z80 CODE\0")
        if i >= 0:
            print("BT_BASE=%x" % (start + i - title))
            return
    print("the program isn't in this state (another build's listing?)")


if __name__ == "__main__":
    main()
