"""The sound effects as samples, for an A1200 without fast RAM (src/fx_play.s):
every effect command played through the translated sound program
(src/sound_test.s on tools/harness/sound_sim.c, the timers as modelled), its
YM2203 writes rendered by ymfm (MAME's YM2203 emulation, fetched with git and
built with g++: tools/sound/ym_render.cpp), resampled to Paula's rate and
packed 4 bits a sample.

Packing: blocks of 32 samples, a byte (the step table: 0-4; 5 = silence, no
data) then 16 bytes of two 4-bit steps (high nibble first) added to the
running value. The encoder keeps the value in range and follows the decoder
exactly.

Bank (big-endian): FX_COUNT records of FX_REC bytes, indexed by command:
  +0  l  offset of the first block from the bank start (0: no sample)
  +4  w  blocks
  +6  l  loop: offset of its first block (0: one-shot)
  +10 w  blocks in the loop
  +12 b  value at the loop start
  +13 b  Paula volume (0-64: the effect's loudness)
then the step tables (FX_TABLES x 16 signed bytes), then the blocks.

usage: python3 tools/sound/effects.py build/game/fx_bank.bin build/game/fx_bank.i
"""
import os
import struct
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "tools", "harness"))
import sound_check  # noqa: E402

UNITS = sound_check.UNITS
CLOCK = 3579545
YM_RATE = CLOCK / 24                    # ym_render's output (OPN_FIDELITY_MIN)
PERIOD = 580                            # Paula period (PAL clock): src/fx_play.s
RATE = 3546895 / PERIOD                 # 6115 Hz
BLOCK = 32
FX_COUNT = 0x46                         # commands $00-$45
FX_REC = 14
EFFECTS = list(range(0x01, 0x1F)) + list(range(0x3A, 0x44)) + [0x45]
LOOPS = {0x14: None, 0x3C: 0.25}       # go on until stopped: (fixed loop, s)
GAP = 10.0                              # seconds each effect gets
FIB = [-34, -21, -13, -8, -5, -3, -2, -1, 0, 1, 2, 3, 5, 8, 13, 21]
TABLES = [[max(-127, min(127, round(d * 2 ** (k / 4 - 2)))) for d in FIB] for k in range(24)]
SILENT = len(TABLES)


def ym_render():
    """ymfm (git) and tools/sound/ym_render.cpp (g++) -> the renderer's path."""
    b = os.path.join(ROOT, "build", "sound")
    y = os.path.join(ROOT, "build", "ymfm")
    if not os.path.exists(os.path.join(y, "src", "ymfm_opn.cpp")):
        subprocess.run(["git", "clone", "-q", "--depth", "1", "https://github.com/aaronsgiles/ymfm.git", y],
                       check=True)
    exe = os.path.join(b, "ym_render")
    src = os.path.join(HERE, "ym_render.cpp")
    if not os.path.exists(exe) or os.path.getmtime(exe) < os.path.getmtime(src):
        os.makedirs(b, exist_ok=True)
        s = os.path.join(y, "src")
        subprocess.run(["g++", "-O2", "-std=c++14", "-I" + s, "-o", exe, src] +
                       [os.path.join(s, f) for f in ("ymfm_opn.cpp", "ymfm_ssg.cpp", "ymfm_misc.cpp",
                                                     "ymfm_adpcm.cpp")], check=True)
    return exe


def render_all():
    """Every effect, each after a reset of the sound CPU: {command: samples
    at YM_RATE} (FM and SSG mixed 1:1, as fitted against MAME's output)."""
    t = UNITS
    lines = ["snd_events:", "\tdc.l\t8"]
    starts = {}
    for c in EFFECTS:
        lines.append("\tdc.l\t%d,$101" % t)
        lines.append("\tdc.l\t%d,$100" % (t + 200))
        ts = t + round(0.2 * UNITS)
        starts[c] = ts / UNITS
        lines.append("\tdc.l\t%d,$%02x" % (ts, c))
        lines.append("\tdc.l\t%d,$ff" % (ts + 800))
        t += round(GAP * UNITS)
    lines.append("\tdc.l\t%d,$ff\n\tdc.l\t-1" % t)
    os.makedirs(sound_check.B, exist_ok=True)
    open(os.path.join(sound_check.B, "sound_events.s"), "w").write("\n".join(lines) + "\n")
    log = os.path.join(sound_check.B, "fx_log.txt")
    with open(log, "w") as f:
        for line in sound_check.simulate():
            p = line.split()
            if p[0] == "W":
                f.write("%.6f %s %s %s\n" % (int(p[1]) / UNITS, p[2], p[3], p[4]))
    fm, ssg = (os.path.join(sound_check.B, n) for n in ("fx_fm.f32", "fx_ssg.f32"))
    subprocess.run([ym_render(), log, str(t / UNITS), fm, ssg], check=True)
    x = np.fromfile(fm, dtype=np.float32).astype(float) + np.fromfile(ssg, dtype=np.float32)
    return {c: x[int(s * YM_RATE):int((s + GAP - 0.3) * YM_RATE)] for c, s in starts.items()}


def resample(x):
    """YM_RATE -> RATE: windowed-sinc low-pass at 0.45 RATE, then linear."""
    fc = 0.45 * RATE / YM_RATE
    n = np.arange(-400, 401)
    h = 2 * fc * np.sinc(2 * fc * n) * np.blackman(len(n))
    y = np.convolve(x, h / h.sum(), "same")
    pos = np.arange(0, len(y) - 1, YM_RATE / RATE)
    i = pos.astype(int)
    return y[i] + (y[i + 1] - y[i]) * (pos - i)


def trim(y):
    """Up to where it stays below 2% of its peak (with a short fade)."""
    a = np.abs(y)
    k = max(1, int(RATE * 0.02))
    env = np.convolve(a, np.ones(k) / k, "same")
    above = np.nonzero(env > 0.02 * a.max())[0]
    end = above[-1] + 1 if len(above) else 0
    y = y[:end].copy()
    f = min(len(y), int(RATE * 0.01))
    if f:
        y[-f:] *= np.linspace(1, 0, f)
    return y


def find_loop(y):
    """A looping effect: its period (the shortest that matches the waveform
    nearly as well as the best) -> (start, end) in samples, whole blocks."""
    start = int(RATE * 0.5)
    start -= start % BLOCK
    seg = y[start:]
    seg = seg - seg.mean()
    cands = []
    for p in range(BLOCK * 2, int(RATE * 3.5), BLOCK):
        if p * 2 > len(seg):
            break
        a, b = seg[:len(seg) - p], seg[p:]
        cands.append((np.dot(a, b) / np.sqrt(np.dot(a, a) * np.dot(b, b) + 1e-12), p))
    top = max(c for c, _ in cands)
    corr, period = next((c, p) for c, p in cands if c >= 0.95 * top)
    return start, start + period, corr

def encode(s):
    """8-bit samples (ints) -> blocks (the table that keeps a block closest,
    each step the nearest the value can take); also the value before each
    block, and where each block starts."""
    tabs = np.array(TABLES)                         # tables x 16
    out, values, starts = bytearray(), [], []
    v = 0
    for b0 in range(0, len(s), BLOCK):
        blk = s[b0:b0 + BLOCK]
        values.append(v)
        starts.append(len(out))
        if all(abs(x) <= 1 for x in blk) and abs(v) <= 1:
            out.append(SILENT)
            continue
        vv = np.full(len(TABLES), v)
        err = np.zeros(len(TABLES))
        nib = np.zeros((len(TABLES), BLOCK), dtype=int)
        rows = np.arange(len(TABLES))
        for i, x in enumerate(blk):
            cand = vv[:, None] + tabs
            e = np.abs(cand - x) + np.where((cand < -128) | (cand > 127), 1e9, 0)
            k = e.argmin(axis=1)
            nib[:, i] = k
            vv = cand[rows, k]
            err += (e[rows, k]) ** 2
        t = int(err.argmin())
        v = int(vv[t])
        out.append(t)
        for i in range(0, BLOCK, 2):
            out.append(nib[t, i] << 4 | nib[t, i + 1])
    return bytes(out), values, starts


def main():
    out, inc = sys.argv[1], sys.argv[2]
    cache = os.path.join(sound_check.B, "fx_raw.npz")
    deps = [os.path.join(ROOT, f) for f in ("src/sound.s", "data/sound_entries.txt", "tools/z80/translate.py",
                                            "tools/sound/ym_render.cpp")]
    if os.path.exists(cache) and all(os.path.getmtime(cache) > os.path.getmtime(f) for f in deps):
        z = np.load(cache)
        raw = {int(k): z[k] for k in z.files}
    else:
        raw = render_all()
        np.savez(cache, **{str(c): x for c, x in raw.items()})
    effects = {}
    peak = max(np.abs(x).max() for x in raw.values())
    for c, x in sorted(raw.items()):
        y = resample(x)
        loop = None
        if c in LOOPS and LOOPS[c]:     # (noise: any stretch loops)
            ls = int(RATE * 0.5) // BLOCK * BLOCK
            le, corr = ls + int(RATE * LOOPS[c]) // BLOCK * BLOCK, 0
            y = y[:le]
            loop = ls // BLOCK
        elif c in LOOPS:
            ls, le, corr = find_loop(y)
            y = y[:le]
            loop = ls // BLOCK
            print("  $%02X: loop %.2f-%.2f s (match %.2f)" % (c, ls / RATE, le / RATE, corr))
        else:
            y = trim(y)
        if len(y) == 0:
            continue
        y = np.concatenate([y, np.zeros((-len(y)) % BLOCK)])
        p = np.abs(y).max()
        vol = max(1, min(64, round(64 * p / peak)))
        s = [int(round(v)) for v in np.clip(y / p * 127, -127, 127)]
        effects[c] = (s, loop, vol)
    tables = b"".join(bytes(d & 0xFF for d in t) for t in TABLES)
    head = FX_COUNT * FX_REC
    body = bytearray()
    recs = bytearray(head)
    for c, (s, loop, vol) in sorted(effects.items()):
        data, values, starts = encode(s)
        off = head + len(tables) + len(body)
        nblk = len(s) // BLOCK
        if loop is None:
            loff, lblk, lv = 0, 0, 0
        else:
            loff, lblk, lv = off + starts[loop], nblk - loop, values[loop]
        recs[c * FX_REC:(c + 1) * FX_REC] = struct.pack(">IHIHbB", off, nblk, loff, lblk, lv, vol)
        body += data
    blob = bytes(recs) + tables + bytes(body)
    open(out, "wb").write(blob)
    open(inc, "w").write("FX_SIZE\tequ\t%d\t\t; (tools/sound/effects.py)\nFX_TABLES\tequ\t%d\n"
                         "FX_SILENT\tequ\t%d\nFX_COUNT\tequ\t%d\nFX_REC\tequ\t%d\nFX_PERIOD\tequ\t%d\n" %
                         (len(blob), len(TABLES), SILENT, FX_COUNT, FX_REC, PERIOD))
    secs = sum(len(s) for s, _, _ in effects.values()) / RATE
    print("%s: %d effects, %.1f s at %d Hz, %d bytes" % (out, len(effects), secs, RATE, len(blob)))


if __name__ == "__main__":
    main()
