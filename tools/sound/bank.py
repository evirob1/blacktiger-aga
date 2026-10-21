"""The A1200 player's instrument bank, made from the ROM at build time: plays
every sound command through the translated sound program (src/sound_test.s,
timers as modelled), collects the FM patches it keys on, renders each with
tools/sound/opn.py at the note it plays most, and writes them as 8-bit
samples after a table the player looks patches up in (src/sound_play.s):
BANK_PATCHES records of BP_SIZE bytes (big-endian), then the samples.

usage: python3 tools/sound/bank.py build/game/snd_bank.bin build/game/snd_bank.i
"""
import struct
import math
import os
import pickle
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "tools", "harness"))
import model  # noqa: E402
import opn  # noqa: E402
import sound_check  # noqa: E402

UNITS = sound_check.UNITS
MUSIC = list(range(0x21, 0x38))
EFFECTS = list(range(0x01, 0x1F)) + list(range(0x3A, 0x44))
FM_LEVEL = 0.5                  # FM against SSG (0.8 in the player): as tools/sound/model.py
TL_DB = 0.75


def patch_hash(regs, ch):
    """The player's key for a channel's instrument (src/sound_play.s,
    fm_hash): 16-bit rotate-and-xor over the operator registers ($30-$90
    but the levels, register order) and FB/ALG. (Patches that differ only in
    their modulators' levels share a sample: that of the commonest.)"""
    data = []
    for base in (0x30, 0x50, 0x60, 0x70, 0x80, 0x90):
        data += [regs[base + ch + 4 * k] for k in range(4)]
    data.append(regs[0xB0 + ch] & 0x3F)
    h = 0
    for b in data:
        h = ((h << 3) | (h >> 13)) & 0xFFFF
        h ^= b
    return h


def capture():
    """Play every command; the patches keyed on: {hash: {patch key: {frequency: count}}}."""
    t = UNITS
    lines = ["snd_events:", "\tdc.l\t1"]
    for cmd in MUSIC + EFFECTS:
        lines.append("\tdc.l\t%d,$%02x" % (t, cmd))
        lines.append("\tdc.l\t%d,$ff" % (t + 800))
        t += round((40 if cmd in MUSIC else 4) * UNITS)
    lines.append("\tdc.l\t%d,$ff\n\tdc.l\t-1" % t)
    os.makedirs(sound_check.B, exist_ok=True)
    open(os.path.join(sound_check.B, "sound_events.s"), "w").write("\n".join(lines) + "\n")
    regs = [[0] * 256 for _ in range(2)]
    keyed = [[False] * 3 for _ in range(2)]
    found = {}
    for line in sound_check.simulate():
        f = line.split()
        if f[0] != "W":
            continue
        chip, reg, val = int(f[2]), int(f[3], 16), int(f[4], 16)
        regs[chip][reg] = val
        if reg == 0x28 and val & 3 < 3:
            ch, on = val & 3, val >> 4 != 0
            if on and not keyed[chip][ch]:
                h = patch_hash(regs[chip], ch)
                key = model.patch_key(regs[chip], ch)
                e = found.setdefault(h, {})
                if any((k[0], k[2]) != (key[0], key[2]) for k in e):
                    raise SystemExit("patch hash collision: %04x" % h)
                fq = round(opn.freq(*model.fnum_block(regs[chip], ch)), 1)
                e.setdefault(key, {})
                e[key][fq] = e[key].get(fq, 0) + 1
            keyed[chip][ch] = on
    return found


def main():
    out, inc = sys.argv[1], sys.argv[2]
    cache = os.path.join(sound_check.B, "patches.pickle")
    src = [os.path.join(ROOT, f) for f in ("data/sound_entries.txt", "src/sound.s", "tools/z80/translate.py")]
    if os.path.exists(cache) and os.path.getmtime(cache) > os.path.getmtime(__file__) and all(os.path.getmtime(cache) > os.path.getmtime(f) for f in src):
        found = pickle.load(open(cache, "rb"))
    else:
        found = capture()
        pickle.dump(found, open(cache, "wb"))
    entries, blob = [], bytearray()
    for h in sorted(found):
        variants = found[h]             # (the commonest levels)
        key = max(variants, key=lambda k: sum(variants[k].values()))
        freqs = {}
        for v in variants.values():
            for fq, n in v.items():
                freqs[fq] = freqs.get(fq, 0) + n
        f_ref = max(freqs, key=freqs.get)
        s = model.Sample(key, f_ref)
        peak = float(np.abs(s.data).max()) or 1.0
        data = np.round(s.data / peak * 127).astype(int)
        start = len(blob)
        blob += bytes((v & 0xFF) for v in data)
        if len(blob) & 1:
            blob.append(0)
        # loudness of the sample at full scale, as attenuation in TL steps
        att = max(0, round(-20 * math.log10(peak * FM_LEVEL) / TL_DB))
        # pitch: step (16.16, sample positions per output sample: the samples
        # are at half the output rate) = (fnum << block) * K >> 8
        k = opn.CLOCK / (144 * 16 * s.f_ref) * 256 / model.SDIV
        # release: the slowest carrier's rate, in 1/16 TL steps per player chunk
        p = {b: list(v) for b, v in zip((0x30, 0x50, 0x60, 0x70, 0x80, 0x90), key[0])}
        rr = min((p[0x80][c] & 15) * 4 + 2 for c in model.CARRIERS[key[2] & 7])
        t96 = 1023 / max(opn.eg_inc(rr), 1e-9) / (opn.RATE / 3)
        rel = round(96 / TL_DB * 16 * (model.CHUNK / model.RATE) / t96)
        # the fade while held, once in the loop (1/16 TL steps per chunk): the
        # rest of the decay to the sustain level (rate, total), then the
        # sustain rate
        per = 16 / TL_DB * model.CHUNK / model.RATE
        fade1, total1 = round(s.decay1 * per), round(s.decay1_db / TL_DB * 16)
        fade2 = round(s.decay * per)
        loop = -1 if s.loop is None else start + s.loop
        entries.append((h, att, round(k), min(rel, 32767), min(fade1, 32767), min(total1, 32767),
                        min(fade2, 32767), start, len(data), loop))
    table = b"".join(struct.pack(">HhhhhhhhIIi", *(e[:7] + (0,) + e[7:])) for e in entries)
    open(out, "wb").write(table + bytes(blob))
    open(inc, "w").write("BANK_PATCHES\tequ\t%d\t\t; (tools/sound/bank.py)\nBANK_SIZE\tequ\t%d\n" %
                         (len(entries), len(table) + len(blob)))
    print("%s: %d patches, %d bytes of samples" % (out, len(entries), len(blob)))


if __name__ == "__main__":
    main()
