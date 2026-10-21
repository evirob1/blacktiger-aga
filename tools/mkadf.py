"""Build a bootable 880K ADF: bootblock + payload, packed with tools/lzpack.py
(the bootblock unpacks it).

usage: python3 tools/mkadf.py boot.bin payload.bin BSS_BYTES out.adf [CHIPA CHIPB]
(tools/build_game.py also passes the sound data)
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


def build(boot_path, payload_path, bss, out, chipa=0, chipb=0, sound_path=None, sound_size=0,
          bss_end=0, fx_path=None, fx_size=0, fx_lite=0):
    """sound_path: the sound data (the sound program's ROM + the instrument
    bank), after the payload on the disk; with fast RAM the bootblock puts it
    at the end of the program's block, sound_size bytes there (its window,
    the ROM, the bank). fx_path: the effects' samples (fx_size bytes), after
    it on the disk, not packed: without fast RAM they go at the end of the
    one block instead (bss_end: where chip area B starts in it)."""
    boot = bytearray(open(boot_path, "rb").read())
    payload = open(payload_path, "rb").read()
    packed = pack_cached(payload, payload_path + ".lz")
    sound = pack_cached(open(sound_path, "rb").read(), sound_path + ".lz") if sound_path else b""
    if not sound_path:
        sound_size = 0
    load = (len(payload) + 511) & ~511          # unpacked, as laid out in memory
    disk = (len(packed) + 511) & ~511
    sdisk = (len(sound) + 511) & ~511
    fx = open(fx_path, "rb").read() if fx_path else b""
    fxdisk = (len(fx) + 511) & ~511
    fxlite = (min(fx_lite or len(fx), len(fx)) + 511) & ~511      # (short of chip RAM: without the
                                                                 # optional effects, at the end)
    if 1024 + disk + sdisk + fxdisk > ADF_SIZE:
        raise SystemExit("too big for an ADF: %d bytes (%d over)" %
                         (1024 + disk + sdisk + fxdisk, 1024 + disk + sdisk + fxdisk - ADF_SIZE))
    # unpacked in place: the packed data sits at the top of the block, and the
    # output, growing from the bottom, must never reach the data still unread
    if load + bss - disk < lead(packed) + 16:
        raise SystemExit("the packed payload would overwrite itself while unpacking")
    chipa = (chipa + 7) & ~7
    fast_at = (load + bss + 7) & ~7             # the sound data's place
    quiet = (max(load + bss, bss_end + chipb) + 7) & ~7
    fast, chip, stock = fast_at + sound_size, chipa + chipb, quiet + fxdisk
    stock_lite = quiet + fxlite
    if sound_path and fast_at - sdisk < load:
        raise SystemExit("no room below the sound data for it packed")
    if sound_path:                              # (for tools/harness/sim_env.sh)
        open(sound_path + ".at", "w").write("%x %x\n" % (quiet + 0x4000, fast_at + 0x4000))
    if fx_path:
        open(fx_path + ".at", "w").write("%x\n" % quiet)
    # the bootblock's last eleven longs (src/boot.s)
    boot[len(boot) - 44:len(boot)] = struct.pack(">IIIIIIIIIII", disk, sdisk, fast, chip, stock, quiet,
                                                 fast_at + 0x4000, quiet, fxdisk, stock_lite, fxlite)
    block = bytearray(1024)
    block[:len(boot)] = boot
    block[4:8] = b"\0\0\0\0"
    block[4:8] = struct.pack(">I", checksum(block))
    adf = bytearray(ADF_SIZE)
    adf[:1024] = block
    adf[1024:1024 + len(packed)] = packed
    adf[1024 + disk:1024 + disk + len(sound)] = sound
    adf[1024 + disk + sdisk:1024 + disk + sdisk + len(fx)] = fx
    open(out, "wb").write(adf)
    used = 1024 + disk + sdisk + fxdisk
    print("%s: payload %d bytes (%d packed), sound %d packed, effects %d, bss %d, %d%% of disk used "
          "(%d KB free)" % (out, len(payload), len(packed), len(sound), len(fx), bss, used * 100 // ADF_SIZE,
                            (ADF_SIZE - used) // 1024))
    if chipb and sound_path:
        print("  memory: %d KB of chip RAM with the effects (%d KB without the story tune, %d KB without"
              " any), or %d KB fast + %d KB chip with all the sound" %
              (stock // 1024, stock_lite // 1024, quiet // 1024, fast // 1024, chip // 1024))
    elif chipb:
        print("  memory: %d KB of chip RAM, or %d KB fast + %d KB chip (no sound)" %
              (stock // 1024, fast // 1024, chip // 1024))


if __name__ == "__main__":
    build(sys.argv[1], sys.argv[2], int(sys.argv[3], 0), sys.argv[4],
          *(int(a, 0) for a in sys.argv[5:7]))   # (no sound data)
