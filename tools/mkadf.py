"""Build a bootable 880K ADF: bootblock + raw payload.

usage: python3 tools/mkadf.py boot.bin payload.bin BSS_BYTES out.adf [CHIPA CHIPB]
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


def build(boot_path, payload_path, bss, out, chipa=0, chipb=0):
    boot = bytearray(open(boot_path, "rb").read())
    payload = open(payload_path, "rb").read()
    load = (len(payload) + 511) & ~511
    if 1024 + load > ADF_SIZE:
        raise SystemExit("payload too big for ADF: %d bytes" % len(payload))
    # the last four longs of the bootblock code: load_size, fast_size (payload
    # + BSS), chip_size (chip areas A + B), stock_size (payload + BSS + area B)
    chipa = (chipa + 7) & ~7
    boot[len(boot) - 16:len(boot)] = struct.pack(">IIII", load, load + bss, chipa + chipb,
                                                 load + bss + chipb)
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
    if chipb:
        print("  memory: %d KB of chip RAM, or %d KB fast + %d KB chip" %
              ((load + bss + chipb) // 1024, (load + bss) // 1024, (chipa + chipb) // 1024))


if __name__ == "__main__":
    build(sys.argv[1], sys.argv[2], int(sys.argv[3], 0), sys.argv[4],
          *(int(a, 0) for a in sys.argv[5:7]))
