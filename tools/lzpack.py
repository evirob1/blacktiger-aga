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


def pack(data, chain=64):
    """Optimal parse: the longest match at each position (hash chains), then
    the cheapest way through (a literal run's header counted once)."""
    n = len(data)
    best_len, best_dist = [0] * n, [0] * n
    heads = {}
    for i in range(n - 2):
        key = data[i:i + 3]
        chain_i = heads.get(key)
        if chain_i is None:
            heads[key] = [i]
            continue
        best, bd, lim = 0, 0, min(MAX_MATCH, n - i)
        for j in reversed(chain_i[-chain:]):
            d = i - j
            if d > MAX_DIST:
                break
            if best >= lim:
                break
            if data[j + best] != data[i + best]:
                continue
            k = MIN_MATCH
            while k < lim:
                step = min(16, lim - k)
                if data[j + k:j + k + step] == data[i + k:i + k + step]:
                    k += step
                else:
                    while data[j + k] == data[i + k]:
                        k += 1
                    break
            if k > best:
                best, bd = k, d
        best_len[i], best_dist[i] = best, bd
        chain_i.append(i)
    # from the end: fresh[i] = the cost from i, run[i] = ... with a literal
    # run open (its header paid), take[i] = the match length to use at i
    inf = 1 << 60
    fresh, run, take = [0] * (n + 1), [0] * (n + 1), [0] * (n + 1)
    for i in range(n - 1, -1, -1):
        m, ml = inf, 0
        for ln in range(MIN_MATCH, best_len[i] + 1):
            c = 3 + fresh[i + ln]
            if c < m:
                m, ml = c, ln
        take[i] = ml
        run[i] = min(1 + run[i + 1], m)
        fresh[i] = min(2 + run[i + 1], m)
    out, lit = bytearray(), bytearray()

    def flush():
        p = 0
        while p < len(lit):
            k = min(128, len(lit) - p)
            out.append(k - 1)
            out.extend(lit[p:p + k])
            p += k
        lit.clear()

    i, open_run = 0, False
    while i < n:
        m = 3 + fresh[i + take[i]] if take[i] else inf
        if (1 if open_run else 2) + run[i + 1] <= m:
            lit.append(data[i])
            i += 1
            open_run = True
        else:
            flush()
            out.append(0x80 | (take[i] - 3))
            out.extend(best_dist[i].to_bytes(2, "big"))
            i += take[i]
            open_run = False
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
