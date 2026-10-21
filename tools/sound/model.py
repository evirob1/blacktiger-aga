"""A model of the A1200 sound player, to try it out against MAME before it is
written in 68k: plays a log of YM2203 writes (tools/mame/sound_log.lua, with
time stamps) the way the player will, and writes a WAV.

The player mixes 12 voices at RATE in chunks of CHUNK samples, taking the
chips' registers as they are at the start of each chunk:
  * the 6 FM channels play samples, one per instrument patch (operator
    registers and modulator levels at key on), rendered by tools/sound/opn.py
    at the note the patch plays most: one-shot for sounds that die away,
    looped once the envelope settles for held ones. Pitch from the F-number,
    loudness from the carriers' levels, a release ramp from key off.
  * the 6 SSG channels play a square wave or noise at the chip's frequency
    and volume.

usage: python3 tools/sound/model.py analysis/sound/ym_ref.txt out.wav [from_s to_s]
"""
import math
import sys
import wave

import numpy as np

import opn

PERIOD = int(__import__("os").environ.get("BT_PERIOD", "384"))   # Paula period (PAL clock): src/sound_play.s
RATE = 3546895 / PERIOD
SRATE = 3546895 / 512             # samples stored at this rate,
SDIV = RATE / SRATE               # RATE / SDIV
CHUNK = 96
CLOCK = opn.CLOCK
SSG_CLOCK = CLOCK / float(__import__("os").environ.get("BT_SSGDIV", "2"))   # YM2203 SSG, default prescaler
AY_VOL = [0.0, 0.0137, 0.0205, 0.0291, 0.0423, 0.0618, 0.0847, 0.1369,
          0.1691, 0.2647, 0.3527, 0.4499, 0.5704, 0.6873, 0.8482, 1.0]
CARRIERS = {0: [3], 1: [3], 2: [3], 3: [3], 4: [1, 3], 5: [1, 2, 3], 6: [1, 2, 3], 7: [0, 1, 2, 3]}
FM_GAIN = float(__import__("os").environ.get("BT_FMGAIN", "0.25"))
FM_FMUL = float(__import__("os").environ.get("BT_FMUL", "1"))
MERGE = __import__("os").environ.get("BT_MERGE", "1") == "1"
SSG_GAIN = float(__import__("os").environ.get("BT_SSGGAIN", "0.4"))


def patch_key(regs, ch):
    """The patch at key on: operator registers and FB/ALG, the modulators'
    levels (timbre) but not the carriers' (loudness)."""
    p = opn.patch_regs(regs, ch)
    alg = p[0xB0] & 7
    tl = [p[0x40][s] if s not in CARRIERS[alg] else 0 for s in range(4)]
    return (tuple(tuple(p[b]) for b in (0x30, 0x50, 0x60, 0x70, 0x80, 0x90)), tuple(tl), p[0xB0] & 0x3F)


def carrier_tl(regs, ch):
    p = opn.patch_regs(regs, ch)
    return min(p[0x40][s] & 0x7F for s in CARRIERS[p[0xB0] & 7])


def fnum_block(regs, ch):
    return (regs[0xA4 + ch] & 7) << 8 | regs[0xA0 + ch], regs[0xA4 + ch] >> 3 & 7


class Sample:
    """A patch rendered at f_ref: data (floats) and, for a sound that holds,
    the loop start (None: one-shot) and how it fades from there while held,
    which the player does: decay1 dB/s for decay1_db (the carriers' decay to
    their sustain level, if not done), then decay dB/s (sustain rate)."""

    ONE_SHOT = 0.5              # gone (-48 dB) within this: kept whole
    SETTLE = (0.02, float(__import__("os").environ.get("BT_SETTLE", "0.09")))  # held: the attack kept (at most), then a loop

    def __init__(self, key, f_ref):
        ops, tl, fbalg = key
        bases = (0x30, 0x50, 0x60, 0x70, 0x80, 0x90)
        p = {b: list(v) for b, v in zip(bases, ops)}
        p[0x40] = list(tl)
        p[0xB0] = fbalg
        car = CARRIERS[fbalg & 7]
        fnum, block = self.note(max(f_ref, 30.0))
        self.f_ref = opn.freq(fnum, block) * FM_FMUL
        data = np.array(opn.render(p, fnum, block, 0.7, rate=SRATE))
        env = np.array([np.abs(data[i:i + 64]).max() for i in range(0, len(data), 64)])
        peak = env.max() or 1.0
        top = int(env.argmax())
        gone = next((i for i in range(top, len(env)) if env[i:].max() < peak * 0.004), None)
        self.decay = self.decay1 = self.decay1_db = 0.0
        if gone is not None and gone * 64 < self.ONE_SHOT * SRATE:
            self.data, self.loop = data[:max(gone, 1) * 64], None      # (silent: a little)
            return
        # where the carriers have finished their attack and decay
        kc = opn.keycode(fnum, block)
        ops_ = [opn.Operator(p, s, kc) for s in car]
        t, step = 0, opn.EG_EVERY / opn.RATE
        while t < self.SETTLE[1] and any(o.stage in ("attack", "decay") for o in ops_):
            for o in ops_:
                o.eg_step()
            t += step
        settle = int(max(t, self.SETTLE[0]) * SRATE)
        # (not settled yet: the rest of the decay to the sustain level, by the
        # loudest carrier)
        lead = min(ops_, key=lambda o: o.att)
        self.decay1_db = max(0.0, (lead.sl - lead.att) * 0.09375) if lead.stage == "decay" else 0.0
        self.decay1 = opn.eg_inc(lead.dr) * (opn.RATE / 3) * 0.09375
        # loop whole periods of the fundamental from there
        g = 0
        for s in range(4):
            m = p[0x30][s] & 15
            g = math.gcd(g, 1 if m == 0 else 2 * m)
        period = SRATE / (self.f_ref * g / 2)
        n = round(period * max(1, round(256 / period)))
        self.data, self.loop = data[:settle + n], settle
        # the fade while held: the slowest carrier's sustain rate
        rates = [o.sr for o in ops_]
        self.decay = 0.0 if 0 in rates else min(opn.eg_inc(r) for r in rates) * (opn.RATE / 3) * 0.09375

    @staticmethod
    def note(f):
        """F-number and block for frequency f."""
        for block in range(8):
            fnum = round(f / (2 ** (block - 1) * CLOCK / (144 * 2 ** 20) * 2))
            if fnum < 2048:
                return fnum, block
        return 2047, 7


class Player:
    def __init__(self, notes):
        self.regs = [[0] * 256 for _ in range(2)]
        self.samples = {}
        self.notes = notes          # patch key -> most played frequency
        self.merged = {}
        for k in sorted(notes, key=lambda k: -notes.get(k, 0) if False else 0):
            self.merged.setdefault((k[0], k[2]), k)
        self.fm = [dict(on=False, s=None, pos=0.0, rel=1.0) for _ in range(6)]
        self.ssg = [dict(phase=0.0) for _ in range(6)]
        self.noise = np.random.default_rng(1).choice([-1.0, 1.0], 1 << 15)
        self.npos = [0.0, 0.0]

    def write(self, chip, reg, val):
        old = self.regs[chip][reg]
        self.regs[chip][reg] = val
        if reg == 0x28 and val & 3 < 3:
            v = self.fm[chip * 3 + (val & 3)]
            on = val >> 4 != 0
            if on and not v["on"]:
                v["start"] = True
            v["on"] = on
        return old

    def sample_for(self, chip, ch):
        key = patch_key(self.regs[chip], ch)
        if MERGE:                       # one sample per instrument (its commonest levels)
            key = self.merged.get((key[0], key[2]), key)
        if key not in self.samples:
            self.samples[key] = Sample(key, self.notes.get(key, 261.6))
        return self.samples[key]

    def chunk(self):
        out = np.zeros(CHUNK)
        dt = CHUNK / RATE
        for i, v in enumerate(self.fm):
            chip, ch = divmod(i, 3)
            regs = self.regs[chip]
            if v.pop("start", False):
                v["s"], v["pos"], v["rel"], v["faded"] = self.sample_for(chip, ch), 0.0, 1.0, 0.0
            s = v["s"]
            if s is None:
                continue
            if not v["on"]:
                # release: the slowest carrier's rate, 96 dB in its time
                p = opn.patch_regs(regs, ch)
                rr = min((p[0x80][c] & 15) * 4 + 2 for c in CARRIERS[p[0xB0] & 7])
                t96 = 1023 / max(opn.eg_inc(rr), 1e-9) / (opn.RATE / 3)
                v["rel"] *= 10 ** (-96 / 20 * dt / t96)
                if v["rel"] < 0.002:
                    v["s"] = None
                    continue
            if v["on"] and s.loop is not None and v["pos"] >= s.loop:
                done = v.setdefault("faded", 0.0)
                rate = s.decay1 if done < s.decay1_db else s.decay
                v["faded"] = done + rate * dt
                v["rel"] *= 10 ** (-rate * dt / 20)
                if v["rel"] < 0.002:
                    v["s"] = None
                    continue
            fnum, block = fnum_block(regs, ch)
            f = opn.freq(fnum, block) * FM_FMUL
            step = f / s.f_ref / SDIV
            gain = 10 ** (-0.75 * carrier_tl(regs, ch) / 20) * v["rel"] * FM_GAIN
            idx = v["pos"] + step * np.arange(CHUNK)
            n = len(s.data)
            if s.loop is None:
                ok = idx < n - 1
                vals = np.where(ok, s.data[np.minimum(idx.astype(int), n - 1)], 0.0)
                if not ok.all():
                    v["s"] = None
            else:
                ll = n - s.loop
                over = idx >= n
                idx = np.where(over, s.loop + (idx - s.loop) % ll, idx)
                vals = s.data[idx.astype(int)]
            v["pos"] = idx[-1] + step if v["s"] is not None else 0
            if s.loop is not None and v["pos"] >= n:
                v["pos"] = s.loop + (v["pos"] - s.loop) % (n - s.loop)
            out += vals * gain
        for chip in range(2):
            regs = self.regs[chip]
            nper = regs[6] & 31 or 1
            nstep = SSG_CLOCK / (16 * nper) / RATE
            nidx = (self.npos[chip] + nstep * np.arange(CHUNK)).astype(int) % len(self.noise)
            self.npos[chip] = (self.npos[chip] + nstep * CHUNK) % len(self.noise)
            for ch in range(3):
                v = self.ssg[chip * 3 + ch]
                vol = AY_VOL[regs[8 + ch] & 15] * SSG_GAIN
                tone = not regs[7] >> ch & 1
                noise = not regs[7] >> (ch + 3) & 1
                if vol == 0 or not (tone or noise):
                    continue
                if noise:
                    out += self.noise[nidx] * vol
                    continue
                per = (regs[2 * ch + 1] & 15) << 8 | regs[2 * ch] or 1
                f = SSG_CLOCK / (16 * per)
                ph = v["phase"] + f / RATE * np.arange(1, CHUNK + 1)
                v["phase"] = ph[-1] % 1.0
                out += np.where(ph % 1.0 < 0.5, 1.0, -1.0) * vol
        return out


def most_played(path):
    """patch key -> the frequency it plays most (from a log)."""
    regs = [[0] * 256 for _ in range(2)]
    keyed = [[False] * 3 for _ in range(2)]
    counts = {}
    for line in open(path):
        f = line.split()
        if f[0] != "W":
            continue
        chip, reg, val = int(f[2]), int(f[3], 16), int(f[4], 16)
        regs[chip][reg] = val
        if reg == 0x28 and val & 3 < 3:
            ch, on = val & 3, val >> 4 != 0
            if on and not keyed[chip][ch]:
                key = patch_key(regs[chip], ch)
                fq = round(opn.freq(*fnum_block(regs[chip], ch)), 1)
                counts.setdefault(key, {}).setdefault(fq, 0)
                counts[key][fq] += 1
            keyed[chip][ch] = on
    return {k: max(v, key=v.get) for k, v in counts.items()}


def main():
    log, out = sys.argv[1], sys.argv[2]
    t0 = float(sys.argv[3]) if len(sys.argv) > 3 else 0.0
    t1 = float(sys.argv[4]) if len(sys.argv) > 4 else 1e9
    writes = []
    for line in open(log):
        f = line.split()
        if f[0] == "W":
            writes.append((float(f[5]), int(f[2]), int(f[3], 16), int(f[4], 16)))
    pl = Player(most_played(log))
    chunks, t, i = [], 0.0, 0
    end = min(t1, writes[-1][0])
    while t < end:
        while i < len(writes) and writes[i][0] <= t:
            pl.write(*writes[i][1:])
            i += 1
        c = pl.chunk()
        if t >= t0:
            chunks.append(c)
        t += CHUNK / RATE
    data = np.concatenate(chunks)
    data = np.clip(data, -1, 1)
    w = wave.open(out, "wb")
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(round(RATE))
    w.writeframes((data * 32000).astype("<i2").tobytes())
    w.close()
    print("%s: %.1f s, %d patches rendered" % (out, len(data) / RATE, len(pl.samples)))


if __name__ == "__main__":
    main()
