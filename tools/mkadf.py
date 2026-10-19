"""Build a bootable 880K ADF: bootblock + raw payload.

usage: python3 tools/mkadf.py boot.bin payload.bin BSS_BYTES out.adf
"""
import struct
import sys

ADF_SIZE = 901120


def checksum(block):
    s = 0
    for i in range(0, 1024, 4):
        s += struct.unpack(">I", block[i:i + 4])[0]
        if s > 0xFFFFFFFF:
            s = (s & 0xFFFFFFFF) + 1
    return (~s) & 0xFFFFFFFF


def build(boot_path, payload_path, bss, out):
    boot = bytearray(open(boot_path, "rb").read())
    payload = open(payload_path, "rb").read()
    load = (len(payload) + 511) & ~511
    if 1024 + load > ADF_SIZE:
        raise SystemExit("payload too big for ADF: %d bytes" % len(payload))
    # the last two longs of the bootblock code are load_size / alloc_size
    boot[len(boot) - 8:len(boot)] = struct.pack(">II", load, load + bss)
    block = bytearray(1024)
    block[:len(boot)] = boot
    block[4:8] = b"\0\0\0\0"
    block[4:8] = struct.pack(">I", checksum(block))
    adf = bytearray(ADF_SIZE)
    adf[:1024] = block
    adf[1024:1024 + len(payload)] = payload
    open(out, "wb").write(adf)
    print("%s: payload %d bytes, bss %d, %d%% of disk used" %
          (out, len(payload), bss, (1024 + load) * 100 // ADF_SIZE))


if __name__ == "__main__":
    build(sys.argv[1], sys.argv[2], int(sys.argv[3], 0), sys.argv[4])
