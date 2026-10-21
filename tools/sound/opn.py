"""YM2203 (OPN) FM voice model, for rendering the game's instrument patches
offline into samples for the A1200 player (tools/sound/patches.py).

Follows the chip's structure: 4 operators (sine, phase modulation of up to
+-4 cycles by the operator before, feedback on operator 1), the 8 algorithms,
the envelope generator (attack / decay / sustain / release on a 10-bit
attenuation in 0.09375 dB steps, updated every 3 samples with the chip's
average increment per rate) and key scaling. Detune and the LFO (the YM2203
has none) are left out.

A patch is the channel's registers: per operator (in register order: slots
1, 3, 2, 4) DT/MUL ($30), TL ($40), KS/AR ($50), DR ($60), SR ($70), SL/RR
($80), and FB/ALG ($B0).
"""
import math

CLOCK = 3579545
RATE = CLOCK / 72                 # FM sample rate (prescaler /6)
EG_EVERY = 3                      # samples per envelope step

# per algorithm: for each operator 1-4 (index 0-3), the operators that modulate
# it, and the carriers (whose outputs are summed)
ALGORITHMS = [
    ({1: [0], 2: [1], 3: [2]}, [3]),
    ({2: [0, 1], 3: [2]}, [3]),
    ({2: [1], 3: [0, 2]}, [3]),
    ({1: [0], 3: [1, 2]}, [3]),
    ({1: [0], 3: [2]}, [1, 3]),
    ({1: [0], 2: [0], 3: [0]}, [1, 2, 3]),
    ({1: [0]}, [1, 2, 3]),
    ({}, [0, 1, 2, 3]),
]


def freq(fnum, block):
    """Note frequency (Hz) of an F-number and block."""
    return fnum * (2 ** (block - 1)) * CLOCK / (144 * 2 ** 20) * 2


def keycode(fnum, block):
    f11, f10, f9, f8 = fnum >> 10 & 1, fnum >> 9 & 1, fnum >> 8 & 1, fnum >> 7 & 1
    n3 = f11 & (f10 | f9 | f8) | (1 - f11) & f10 & f9 & f8
    return block << 2 | f11 << 1 | n3


def eg_inc(rate):
    """Average attenuation change per envelope step at an effective rate 0-63."""
    if rate <= 0:
        return 0.0
    rate = min(rate, 63)
    return (4 + (rate & 3)) / 8 * 2 ** ((rate >> 2) - 11)


class Operator:
    def __init__(self, regs, slot, kc):
        """regs: patch_regs() of the channel; slot 0-3."""
        dtmul, tl, ksar, dr, sr, slrr = (regs[b][slot] for b in (0x30, 0x40, 0x50, 0x60, 0x70, 0x80))
        mul = dtmul & 15
        self.mul = 0.5 if mul == 0 else float(mul)
        self.tl = (tl & 0x7F) << 3
        ks = ksar >> 6
        ksr = kc >> (3 - ks)
        eff = lambda r: 0 if r == 0 else min(63, 2 * r + ksr)
        self.ar, self.dr, self.sr = eff(ksar & 31), eff(dr & 31), eff(sr & 31)
        self.rr = eff((slrr & 15) * 2 + 1)
        sl = slrr >> 4
        self.sl = 1023 if sl == 15 else sl << 5
        self.att = 1023.0
        self.stage = "attack"
        self.phase = 0.0

    def key_off(self):
        self.stage = "release"

    def eg_step(self):
        if self.stage == "attack":
            if self.ar >= 62:
                self.att = 0.0
            else:
                self.att -= (self.att + 1) * eg_inc(self.ar) / 16
            if self.att <= 0:
                self.att, self.stage = 0.0, "decay"
        elif self.stage == "decay":
            self.att += eg_inc(self.dr)
            if self.att >= self.sl:
                self.att, self.stage = float(self.sl), "sustain"
        elif self.stage == "sustain":
            self.att += eg_inc(self.sr)
        else:
            self.att += eg_inc(self.rr)
        self.att = min(self.att, 1023.0)

    def gain(self):
        a = self.att + self.tl
        return 0.0 if a >= 1023 else 10 ** (-a * 0.09375 / 20)


def patch_regs(regs, ch):
    """{base: [slot1, slot2, slot3, slot4]} and FB/ALG from a 256-byte register
    image (channel 0-2)."""
    out = {}
    for base in (0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90):
        vals = [regs[base + ch + 4 * k] for k in range(4)]      # register order 1, 3, 2, 4
        out[base] = [vals[0], vals[2], vals[1], vals[3]]        # slot order 1, 2, 3, 4
    out[0xB0] = regs[0xB0 + ch]
    return out


def render(patch, fnum, block, seconds, key_off=None, rate=RATE):
    """Samples (floats, about -1..1) of one note; key_off: seconds."""
    kc = keycode(fnum, block)
    ops = [Operator(patch, s, kc) for s in range(4)]
    fb = patch[0xB0] >> 3 & 7
    mods, carriers = ALGORITHMS[patch[0xB0] & 7]
    f = freq(fnum, block)
    step = RATE / rate
    out = []
    prev = [0.0, 0.0]
    n = int(seconds * rate)
    eg_acc = 0.0
    two_pi = 2 * math.pi
    for i in range(n):
        if key_off is not None and i == int(key_off * rate):
            for o in ops:
                o.key_off()
        eg_acc += step
        while eg_acc >= EG_EVERY:
            eg_acc -= EG_EVERY
            for o in ops:
                o.eg_step()
        res = [0.0] * 4
        for k in range(4):
            o = ops[k]
            o.phase += f * o.mul / rate
            if k == 0:
                m = (prev[0] + prev[1]) * 2 ** (fb - 7) if fb else 0.0
            else:
                m = sum(res[j] for j in mods.get(k, [])) * 4
            res[k] = math.sin(two_pi * (o.phase + m)) * o.gain()
        prev = [prev[1], res[0]]
        out.append(sum(res[c] for c in carriers))
    return out
