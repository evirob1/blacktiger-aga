"""Build a bootable 880K ADF: bootblock + payload, packed with tools/lzpack.py
(the bootblock unpacks it).

usage: python3 tools/mkadf.py boot.bin payload.bin BSS_BYTES out.adf [CHIPA CHIPB]
"""
import hashlib
import os
import struct
import sys

import lzpack

ADF_SIZE = 901120


def checksum(block):
    s = 0
    for i in range(0, 1024, 4):
        s += struct.unpack(">I", block[i:i + 4])[0]
        if s > 0xFFFFFFFF:
            s = (s & 0xFFFFFFFF) + 1
    return (~s) & 0xFFFFFFFF


def lead(packed):
    """How far the unpacked output gets ahead of the packed input, at most."""
    p = out = worst = 0
    while packed[p] != 0xFF:
        t = packed[p]
        if t < 0x80:
            p, out = p + 1 + t + 1, out + t + 1
        else:
            p, out = p + 3, out + (t & 0x7F) + 3
        worst = max(worst, out - p)
    return worst


def pack_cached(data, cache):
    """lzpack.pack, kept next to the payload while it hasn't changed."""
    key = hashlib.sha1(data).hexdigest().encode() + b"\n"
    if os.path.exists(cache):
        blob = open(cache, "rb").read()
        if blob.startswith(key):
            return blob[len(key):]
    packed = lzpack.pack(data)
    open(cache, "wb").write(key + packed)
    return packed


def build(boot_path, payload_path, bss, out, chipa=0, chipb=0):
    boot = bytearray(open(boot_path, "rb").read())
    payload = open(payload_path, "rb").read()
    packed = pack_cached(payload, payload_path + ".lz")
    load = (len(payload) + 511) & ~511          # unpacked, as laid out in memory
    disk = (len(packed) + 511) & ~511
    if 1024 + disk > ADF_SIZE:
        raise SystemExit("payload too big for ADF: %d bytes packed" % len(packed))
    # unpacked in place: the packed data sits at the top of the block, and the
    # output, growing from the bottom, must never reach the data still unread
    if load + bss - disk < lead(packed) + 16:
        raise SystemExit("the packed payload would overwrite itself while unpacking")
    # the last four longs of the bootblock code: load_size (packed, on disk),
    # fast_size (payload + BSS), chip_size (chip areas A + B), stock_size
    # (payload + BSS + area B)
    chipa = (chipa + 7) & ~7
    boot[len(boot) - 16:len(boot)] = struct.pack(">IIII", disk, load + bss, chipa + chipb,
                                                 load + bss + chipb)
    block = bytearray(1024)
    block[:len(boot)] = boot
    block[4:8] = b"\0\0\0\0"
    block[4:8] = struct.pack(">I", checksum(block))
    adf = bytearray(ADF_SIZE)
    adf[:1024] = block
    adf[1024:1024 + len(packed)] = packed
    open(out, "wb").write(adf)
    print("%s: payload %d bytes (%d packed), bss %d, %d%% of disk used" %
          (out, len(payload), len(packed), bss, (1024 + disk) * 100 // ADF_SIZE))
    if chipb:
        print("  memory: %d KB of chip RAM, or %d KB fast + %d KB chip" %
              ((load + bss + chipb) // 1024, (load + bss) // 1024, (chipa + chipb) // 1024))


if __name__ == "__main__":
    build(sys.argv[1], sys.argv[2], int(sys.argv[3], 0), sys.argv[4],
          *(int(a, 0) for a in sys.argv[5:7]))
