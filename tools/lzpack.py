"""Small LZ77 packer for the game data (unpacked at boot by lz_unpack in
src/amiga_main.s).

Stream of tokens:
  t = $00-$7F        literal run: t+1 bytes follow
  t = $80-$FE        match: length (t & $7F) + 3, then 16-bit big-endian
                     distance (1-65535) back into the output
  t = $FF            end
"""
import sys

MIN_MATCH, MAX_MATCH = 3, 0x7E + 3
MAX_DIST = 65535


def pack(data):
    out = bytearray()
    lit = bytearray()
    heads = {}
    i, n = 0, len(data)

    def flush():
        p = 0
        while p < len(lit):
            k = min(128, len(lit) - p)
            out.append(k - 1)
            out.extend(lit[p:p + k])
            p += k
        lit.clear()

    while i < n:
        best_len, best_dist = 0, 0
        if i + MIN_MATCH <= n:
            key = data[i:i + 3]
            for j in reversed(heads.get(key, [])[-48:]):
                d = i - j
                if d > MAX_DIST:
                    break
                k = 3
                while k < MAX_MATCH and i + k < n and data[j + k] == data[i + k]:
                    k += 1
                if k > best_len:
                    best_len, best_dist = k, d
                    if k == MAX_MATCH:
                        break
        if best_len >= MIN_MATCH:
            flush()
            out.append(0x80 | (best_len - 3))
            out.extend(best_dist.to_bytes(2, "big"))
            for p in range(i, i + best_len):
                if p + 3 <= n:
                    heads.setdefault(data[p:p + 3], []).append(p)
            i += best_len
        else:
            lit.append(data[i])
            if i + 3 <= n:
                heads.setdefault(data[i:i + 3], []).append(i)
            i += 1
    flush()
    out.append(0xFF)
    return bytes(out)


def unpack(blob):
    out = bytearray()
    p = 0
    while True:
        t = blob[p]
        p += 1
        if t == 0xFF:
            return bytes(out)
        if t < 0x80:
            out.extend(blob[p:p + t + 1])
            p += t + 1
        else:
            ln = (t & 0x7F) + 3
            d = blob[p] << 8 | blob[p + 1]
            p += 2
            for _ in range(ln):
                out.append(out[-d])


def main():
    src, dst = sys.argv[1], sys.argv[2]
    data = open(src, "rb").read()
    packed = pack(data)
    assert unpack(packed) == data
    open(dst, "wb").write(packed)
    print("%s: %d -> %d bytes" % (src, len(data), len(packed)))


if __name__ == "__main__":
    main()
