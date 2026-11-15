"""The music for an A1200 without fast RAM (src/trk_play.s): the game's
tunes as notes on Paula's four channels, made from the ROM at build time.

Every tune command is played through the translated sound program
(src/sound_test.s on tools/harness/sound_sim.c, the timers as modelled). Its
YM2203 writes are six FM voices; every note keeps its pitch and level, so
each is a sample started at a period with a volume, then faded as the
chip's envelope would (decay, sustain, release: rates per block, as the fast
RAM player's, src/sound_play.s).

Six voices into four channels: notes are given channels in order, the most
important first (loud, the top and the bottom of a chord); a doubling voice
(unison, octave) or an echo voice gets one only if one is free. Within a
memory budget, combined samples - a note with its doubling, its echo, or a
chord struck together - save the notes left out most often for the memory
they take (most saved per KB first).

Samples (8 bits, at SRATE): one per instrument (operators and FB/ALG; the
modulators' levels of its commonest use) per two octaves it plays in,
rendered by ymfm (MAME's YM2203 emulation, tools/sound/ymfm.py): sounds
that die away quickly whole, others up to where they settle, then a loop.

usage: python3 tools/sound/tracker.py build/game/trk_bank.bin build/game/trk_bank.i
       python3 tools/sound/tracker.py --wav outdir [cmd ...]   (renders, as trk_play.s plays)
"""
import math
import os
import pickle
import struct
import sys
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "tools", "harness"))
import sound_check  # noqa: E402
import opn  # noqa: E402
import model  # noqa: E402
import ymfm  # noqa: E402
import bank  # noqa: E402

UNITS = sound_check.UNITS
PAL = 3546895
SRATE = PAL / 512                   # the samples' rate (as the fast RAM bank's)
ECLOCK = 709379                     # CIA timers (PAL)
TICK_YM = 199 * 72 / 3579545       # the sound program's tempo: its timer A (4.0027 ms),
TICK_CIA = round(TICK_YM * ECLOCK)  # which every key on falls on; trk_play.s's timer
TICK = TICK_CIA / ECLOCK
NCH = int(os.environ.get("BT_TRK_NCH", "4"))
BUDGET = int(os.environ.get("BT_TRK_BUDGET", str(20 * 1024)))   # combined samples, bytes
ONE_SHOT = float(os.environ.get("BT_TRK_ONESHOT", "0.15"))   # gone within this: kept whole (else a loop and a fade)
MAX_LOOP = float(os.environ.get("BT_TRK_LOOP", "0.2"))      # (s)
BAND = int(os.environ.get("BT_TRK_BAND", "2"))              # octaves a sample covers
MERGE_MINOR = os.environ.get("BT_TRK_MERGEMINOR") == "1"
EXACT_ENV = os.environ.get("BT_TRK_EXACTENV") == "1"
TL_DB = 0.75

# The tunes: command -> (seconds of it, loop start, loop length) or a tune
# that ends (loop None). Found from the sound program's output by repeating
# key-on sequences (the program plays them over and over, the same notes at
# the same times). ($26's first pass is its loop but for 3% of its notes:
# played as the loop.)
TUNES = {
    0x21: (3.931, 71.401), 0x22: (1.869, 71.613), 0x23: (0.008, 52.128), 0x24: (5.584, 67.622),
    0x25: (0.008, 47.272), 0x26: (1.061, 65.325), 0x27: (60.386, 63.356), 0x28: (82.969, 21.976),
    0x29: (7.369, 29.628), 0x2A: (23.644, 25.399), 0x2B: (0.997, 29.520), 0x2C: (0.797, 38.065),
    0x2D: (0.008, 21.919), 0x2E: (62.243, 25.049),
    0x2F: 7.04, 0x30: 11.62, 0x31: 8.49, 0x32: 6.72, 0x33: 79.23, 0x34: 12.05, 0x35: 2.79,
    0x36: 3.37, 0x37: 3.22,
}
TAIL = 2.0                          # (s) after a tune's end: its last notes' release


def span(cmd):
    """-> (seconds to capture, loop start or None, end of the data)"""
    t = TUNES[cmd]
    if isinstance(t, tuple):
        return t[0] + t[1] + 1.0, t[0], t[0] + t[1]
    return t + TAIL, None, t + TAIL


# ------------------------------------------------------------------ capture
def capture(cmds):
    """Each command after a reset of the sound CPU: {cmd: [(s, chip, reg, value)]}."""
    t = UNITS
    lines = ["snd_events:", "\tdc.l\t8"]
    starts = {}
    for c in cmds:
        lines.append("\tdc.l\t%d,$101" % t)
        lines.append("\tdc.l\t%d,$100" % (t + 200))
        ts = t + round(0.2 * UNITS)
        starts[c] = ts
        lines.append("\tdc.l\t%d,$%02x" % (ts, c))
        lines.append("\tdc.l\t%d,$ff" % (ts + 800))
        t += round((span(c)[0] + 1.0) * UNITS)
    lines.append("\tdc.l\t%d,$ff\n\tdc.l\t-1" % t)
    os.makedirs(sound_check.B, exist_ok=True)
    open(os.path.join(sound_check.B, "sound_events.s"), "w").write("\n".join(lines) + "\n")
    order = sorted(starts.items(), key=lambda x: x[1])
    logs = {c: [] for c in cmds}
    for line in sound_check.simulate():
        p = line.split()
        if p[0] != "W":
            continue
        tm = int(p[1])
        c = None
        for cc, s in order:
            if tm >= s - round(0.2 * UNITS):
                c = cc
        if c is not None:
            logs[c].append(((tm - starts[c]) / UNITS, int(p[2]), int(p[3], 16), int(p[4], 16)))
    return logs


# ------------------------------------------------------------------ notes
class Note:
    """t0, t1 (key on, key off: s), voice, key (patch), fnum, block, f, tl;
    parts: [(patch, pitch ratio, level offset, delay)] - more than one: a
    combined sample; pri: priority; minor: a doubling / echo voice."""


def notes_of(w, tmax):
    regs = [[0] * 256 for _ in range(2)]
    keyed = [[0] * 3 for _ in range(2)]
    cur, out = {}, []
    for tm, chip, reg, val in w:
        if tm > tmax:
            break
        regs[chip][reg] = val
        if reg == 0x28 and val & 3 < 3:
            ch = val & 3
            on = val >> 4
            v = chip * 3 + ch
            if on and not keyed[chip][ch]:
                n = Note()
                n.t0, n.t1, n.voice = tm, None, v
                n.key = model.patch_key(regs[chip], ch)
                n.fnum, n.block = model.fnum_block(regs[chip], ch)
                n.f = opn.freq(n.fnum, n.block)
                n.tl = model.carrier_tl(regs[chip], ch)
                n.parts = [(n.key, 1.0, 0, 0.0)]
                n.minor = False
                cur[v] = n
                out.append(n)
            if not on and keyed[chip][ch] and v in cur:
                cur.pop(v).t1 = tm
            keyed[chip][ch] = on
    for n in cur.values():
        n.t1 = tmax
    out = [n for n in out if n.f > 0 and n.tl < 100]      # (the start-up's silent key-ons)
    return sorted(out, key=lambda n: (n.t0, n.voice))


def groups(notes):
    """Runs of notes struck together (within 2 ms)."""
    i = 0
    while i < len(notes):
        j = i
        while j < len(notes) and notes[j].t0 - notes[i].t0 < 0.002:
            j += 1
        yield notes[i:j]
        i = j


def mark_minor(notes):
    """Doubling voices (unison / octave with a louder or lower note struck
    and released with it) and echo voices (a quieter repeat, the same delay
    throughout): played only if a channel is free; host: (the note, its
    part in a combined sample)."""
    for g in groups(notes):
        for B in g:
            for A in g:
                if A is B or getattr(A, "minor", False) or abs(A.t1 - B.t1) > 0.006:
                    continue
                r = B.f / A.f
                k = min((1.0, 2.0, 4.0), key=lambda k: abs(r - k))
                if abs(r - k) < 0.004 * k and (B.tl > A.tl or (B.tl == A.tl and (k > 1 or B.voice > A.voice))):
                    B.minor = True
                    B.host = (A, (B.key, k, B.tl - A.tl, 0.0))
                    break
    by = {}
    for n in notes:
        by.setdefault((n.key, n.fnum, n.block), []).append(n)
    delays = {}
    for n in notes:
        for m in by[(n.key, n.fnum, n.block)]:
            d = round(n.t0 - m.t0, 3)
            if 0.015 < d < 0.25 and n.voice != m.voice and n.tl > m.tl and \
                    abs((n.t1 - n.t0) - (m.t1 - m.t0)) < 0.008:
                delays[(m.voice, n.voice, d)] = delays.get((m.voice, n.voice, d), 0) + 1
    for (va, vb, d), cnt in sorted(delays.items(), key=lambda x: -x[1]):
        if cnt < 8:
            continue
        for n in notes:
            if n.voice != vb or n.minor:
                continue
            for m in by[(n.key, n.fnum, n.block)]:
                if m.voice == va and abs(n.t0 - m.t0 - d) < 0.0025 and not m.minor:
                    n.minor = True
                    n.host = (m, (n.key, 1.0, n.tl - m.tl, d))
                    break


def set_priorities(notes):
    for g in groups(notes):
        ps = [n.f for n in g if not n.minor]
        for n in g:
            p = -n.tl * TL_DB
            if len(ps) > 1 and not n.minor:
                if n.f >= max(ps) - 1e-6:
                    p += 6
                if n.f <= min(ps) + 1e-6:
                    p += 4
            if n.minor:
                p -= 30
            n.pri = p


# ------------------------------------------------------------------ instruments
class Instruments:
    """The samples: one per (instrument, band) and per accepted combination."""

    def __init__(self, all_notes):
        cnt = {}
        for n in all_notes:
            cnt[n.key] = cnt.get(n.key, 0) + 1
        self.share = {}
        for k in sorted(cnt, key=lambda k: -cnt[k]):
            self.share.setdefault((k[0], k[2]), k)
        if os.environ.get("BT_TRK_NOSHARE") == "1":
            self.share = {}
        self.freqs = {}
        for n in all_notes:
            k = self.base(n.key)
            self.freqs.setdefault(k, {}).setdefault(round(n.f, 1), 0)
            self.freqs[k][round(n.f, 1)] += 1
        self.cache = {}
        self.order = []

    def base(self, key):
        return self.share.get((key[0], key[2]), key)

    def bkey(self, key):
        """(the sample's identity: the key without the levels when shared)"""
        b = self.base(key)
        return (b[0], b[2]) if self.share else b

    def ikey(self, n):
        base = self.base(n.parts[0][0])
        f_most = max(self.freqs[base], key=self.freqs[base].get)
        band = max(-4, min(6, math.floor((math.log2(n.f / f_most) + BAND / 2) / BAND)))
        parts = tuple((self.bkey(p), round(k, 3), max(-24, min(24, round(dt / 2) * 2)),
                       round(d, 3)) for p, k, dt, d in n.parts)
        return parts + (band,)

    def get(self, n):
        """-> the sample record for note n (made if new)."""
        ik = self.ikey(n)
        if ik not in self.cache:
            self.cache[ik] = self.make(n, ik)
            self.order.append(ik)
        return self.cache[ik]

    def make(self, n, ik):
        base = self.base(n.parts[0][0])
        f_most = max(self.freqs[base], key=self.freqs[base].get)
        f_ref = f_most * (2 ** BAND) ** ik[-1]
        old = (model.SRATE, model.Sample.ONE_SHOT)
        model.SRATE, model.Sample.ONE_SHOT = SRATE, ONE_SHOT
        try:
            s0 = model.Sample(base, f_ref)
            if s0.loop is not None:
                s0 = beat_loop(base, s0)
            if len(n.parts) == 1:
                data, loop = s0.data, s0.loop
            else:
                data, loop = combine(s0, [(self.base(p), k, q[2], d) for (p, k, dt, d), q in
                                          zip(n.parts[1:], ik[1:-1])])
        finally:
            model.SRATE, model.Sample.ONE_SHOT = old
        data, loop = words(np.asarray(data, dtype=float), loop)
        peak = float(np.abs(data).max()) or 1.0
        q = np.clip(np.round(data / peak * 127), -127, 127).astype(int)
        rec = dict(data=q, loop=loop, f_ref=s0.f_ref, peak=peak, s0=s0, base=base)
        rec.update(envelope(base, s0))
        return rec

    def size(self, ik):
        return len(self.cache[ik]["data"]) if ik in self.cache else 0


def words(data, loop):
    """Paula plays words: the loop's start and length made even without
    breaking it (its length is whole periods of the note: an odd one is
    stretched by a sample, an odd start loses the first sample)."""
    if loop is None:
        return (data if len(data) % 2 == 0 else np.append(data, 0.0)), None
    if loop & 1:
        data, loop = data[1:], loop - 1
    n = len(data) - loop
    if n & 1:
        seg = data[loop:]
        x = np.arange(n + 1) * n / (n + 1)
        data = np.concatenate([data[:loop], np.interp(x, np.arange(n + 1), np.append(seg, seg[0]))])
    return data, loop


def beat_loop(key, s0):
    """A held sound whose loudness pulses (operators beating): a loop a whole
    number of pulses long (and of the note's periods), so that it doesn't
    swell at every pass; at most MAX_LOOP."""
    ops, tl, fbalg = key
    p = {b: list(v) for b, v in zip((0x30, 0x50, 0x60, 0x70, 0x80, 0x90), ops)}
    p[0x40] = list(tl)
    p[0xB0] = fbalg
    fnum, block = model.Sample.note(s0.f_ref)
    x = ymfm.resample(ymfm.note(p, fnum, block, 0.6), SRATE) * model.YMFM_SCALE
    settle = s0.loop
    per = SRATE / s0.f_ref
    base_n = len(s0.data) - settle
    W = int(0.06 * SRATE)
    seg = x[settle:settle + W]
    best, best_n = -1.0, base_n
    m = 1
    while True:
        n = int(round(per * m))
        m += 1
        if n < base_n * 0.5:
            continue
        if n > MAX_LOOP * SRATE or settle + n + W > len(x):
            break
        other = x[settle + n:settle + n + W]
        cc = float(np.dot(seg, other) / (np.linalg.norm(seg) * np.linalg.norm(other) + 1e-12))
        if cc > best + 0.002:
            best, best_n = cc, n
    s = model.Sample.__new__(model.Sample)
    s.__dict__.update(s0.__dict__)
    s.data, s.loop = x[:settle + best_n], settle
    return s


def combine(s0, parts):
    """The base sample with others mixed in: [(patch, pitch ratio, level
    offset in TL steps, delay s)] -> (data, loop)."""
    sp = [(s0, 1.0, 0)]
    for key, k, dt, d in parts:
        s = model.Sample(key, s0.f_ref * k)
        sp.append((s, 10 ** (-TL_DB * dt / 20), int(round(d * SRATE))))
    looped = any(s.loop is not None for s, _, _ in sp)
    LOOP = int(0.1 * SRATE)
    if looped:
        total = max((s.loop if s.loop is not None else len(s.data)) + off for s, _, off in sp) + LOOP
    else:
        total = max(len(s.data) + off for s, _, off in sp)
    data = np.zeros(total)
    for s, g, off in sp:
        L = total - off
        idx = np.arange(L)
        if s.loop is not None:
            ll = len(s.data) - s.loop
            idx = np.where(idx >= len(s.data), s.loop + (idx - s.loop) % ll, idx)
            data[off:] += s.data[idx] * g
        else:
            m = min(L, len(s.data))
            data[off:off + m] += s.data[:m] * g
    loop = total - LOOP if looped else None
    if loop is not None:                # (a short crossfade into the loop)
        x = min(128, LOOP // 4, loop)
        w = np.linspace(0, 1, x)
        data[total - x:] = data[total - x:] * (1 - w) + data[loop - x:loop] * w
    return data, loop


def envelope(base, s0):
    """The player's fades for a sample (as the fast RAM bank's,
    tools/sound/bank.py): held, once in the loop, the rest of the loudest
    carrier's decay (rate code, total in 1/256 TL steps), then the slowest
    sustain rate; released, per block, all the carriers together. Steps
    per TICK."""
    p = {b: list(v) for b, v in zip((0x30, 0x50, 0x60, 0x70, 0x80, 0x90), base[0])}
    ks = lambda c: p[0x50][c] >> 6
    per_tick = TICK / (model.CHUNK / model.RATE)
    rel = [min(32767, round(bank.release_steps(p, base[2], b) * per_tick)) for b in range(8)]
    c = s0.lead_slot
    dr = (2 * (p[0x60][c] & 31)) << 8 | ks(c)
    c = s0.sr_slot
    sr = (2 * (p[0x70][c] & 31)) << 8 | ks(c)
    return dict(dr=dr, sr=sr, total1=min(32767, round(s0.decay1_db / TL_DB * 256)), rel=rel)


# per envelope rate 0-63: the attenuation step per TICK (1/256 TL steps)
EG_STEPS = [0 if r == 0 else min(32767, round(opn.eg_inc(r) * TICK * (opn.RATE / opn.EG_EVERY) * 32))
            for r in range(64)]


def eg_step(code, fnum, block):
    rate = code >> 8
    if rate == 0:
        return 0
    return EG_STEPS[min(63, rate + (opn.keycode(fnum, block) >> (3 - (code & 3))))]


# ------------------------------------------------------------------ allocation
def allocate(notes, inst, accepted):
    """-> [(note, channel)], {combination: [notes it would save, a note
    with it]}. Notes in order of time, then priority; a note takes a free
    channel, else one whose note is released, else (not a doubling or echo
    voice) the channel of a lower priority note, cutting it short. Left
    out, an accepted combination puts it into its host: the note it doubles
    or echoes, or one struck with it (a chord)."""
    end = [-1.0] * NCH
    off = [-1.0] * NCH
    pri = [0.0] * NCH
    out, wants, placed_all = [], {}, set()
    for g in groups(notes):
        placed = []
        for n in sorted(g, key=lambda n: -n.pri):
            free = [c for c in range(NCH) if end[c] <= n.t0]
            rel = [c for c in range(NCH) if off[c] <= n.t0]
            c = None
            if free:
                c = free[0]
            elif rel:
                c = min(rel, key=lambda c: off[c])
            elif not n.minor:
                v = min(range(NCH), key=lambda c: pri[c])
                if pri[v] < n.pri:
                    c = v
            if c is None:
                if n.minor:
                    hp = n.host
                else:
                    hp = next(((A, (n.key, round(n.f / A.f, 4), n.tl - A.tl, 0.0)) for A in placed
                               if abs(A.t1 - n.t1) < 0.006 and 0.24 < n.f / A.f < 4.2), None)
                if hp is not None and id(hp[0]) in placed_all and len(hp[0].parts) < 3:
                    A, part = hp
                    tmp = Note()
                    tmp.__dict__.update(A.__dict__)
                    tmp.parts = list(A.parts) + [part]
                    ik = inst.ikey(tmp)
                    if ik in accepted:
                        A.parts = tmp.parts
                    else:
                        wants.setdefault(ik, [0, tmp])[0] += 1
                continue
            end[c] = n.t1 + release_time(n, inst)
            off[c] = n.t1
            pri[c] = n.pri
            placed.append(n)
            placed_all.add(id(n))
            out.append((n, c))
    return out, wants


_rel_cache = {}


def release_time(n, inst):
    """Until the note is 40 dB down after key off (s)."""
    base = inst.base(n.parts[0][0])
    k = (base, n.block)
    if k not in _rel_cache:
        p = {b: list(v) for b, v in zip((0x30, 0x50, 0x60, 0x70, 0x80, 0x90), base[0])}
        st = bank.release_steps(p, base[2], n.block)          # 1/256 TL steps per fast RAM chunk
        dbs = st / 256 * TL_DB / (model.CHUNK / model.RATE)
        _rel_cache[k] = 40 / dbs if dbs > 0 else 10.0
    return _rel_cache[k]


# ------------------------------------------------------------------ the data
# A tune: six voice streams (the arcade's FM voices), each note
#   A        bits 7-6: its (gap, length) pair, as one of the voice's last
#            three (0-2, most recent first) or 3: new, its gap and length
#            follow (numbers: < $80 a byte, else $80 | high, low); bit 5: a
#            doubling / echo voice (takes a free channel only); bit 4: the
#            top or bottom of a chord (more important); bits 3-0: 0
#   P        preset: sample and period (the tune's preset table; 255: the
#            index in the next two bytes)
# and commands (A with bits 3-0 not 0): $01 level (TL steps, a byte
# follows); $02 sync (the loop starts here: time from the loop's start, the
# pair cache empty); $03 end (the voice is idle).
NUM = lambda x: bytes([x]) if x < 0x80 else bytes([0x80 | x >> 8, x & 255])


def final_notes(ns, inst, accepted):
    """The tune's notes with the accepted combinations always used (the
    doubling, echo or chord in its host's sample) -> notes."""
    gone = set()
    for g in groups(ns):
        for B in sorted(g, key=lambda n: -n.pri):
            if B.minor:
                A, part = B.host
            else:
                A = next((A for A in sorted(g, key=lambda n: -n.pri) if A is not B and A.pri >= B.pri and
                          id(A) not in gone and abs(A.t1 - B.t1) < 0.006 and 0.24 < B.f / A.f < 4.2), None)
                if A is None:
                    continue
                part = (B.key, round(B.f / A.f, 4), B.tl - A.tl, 0.0)
            if id(A) in gone or len(A.parts) >= 3:
                continue
            tmp = Note()
            tmp.__dict__.update(A.__dict__)
            tmp.parts = list(A.parts) + [part]
            if inst.ikey(tmp) in accepted or (MERGE_MINOR and B.minor):
                A.parts = tmp.parts
                gone.add(id(B))
    return [n for n in ns if id(n) not in gone]


def encode(ns, inst, loop_s, end_s):
    """-> (tune bytes, presets [{rec: sample, per: period, fnum, block}])"""
    tk = lambda s: round(s / TICK_YM)
    loop_t = None if loop_s is None else tk(loop_s)
    end_t = tk(end_s)
    presets, pidx = [], {}
    streams = [bytearray() for _ in range(6)]
    loops = [0] * 6
    st = [dict(t=0, rc=[], lvl=None, synced=False) for _ in range(6)]
    bonus = {}
    for g in groups(ns):
        ps = [n.f for n in g if not n.minor]
        for n in g:
            bonus[id(n)] = len(ps) > 1 and not n.minor and (n.f >= max(ps) - 1e-6 or n.f <= min(ps) + 1e-6)
    for n in ns:
        t0, t1 = tk(n.t0), tk(n.t1)
        if t0 >= end_t:
            continue
        v, b, s = n.voice, streams[n.voice], st[n.voice]
        if loop_t is not None and not s["synced"] and t0 >= loop_t:
            loops[v] = len(b)
            b.append(0x02)
            s.update(t=loop_t, rc=[], lvl=None, synced=True)
        rec = inst.get(n)
        per = max(124, round(PAL / (SRATE * n.f / rec["f_ref"])))
        key = (inst.ikey(n), per)
        if key not in pidx:
            pidx[key] = len(presets)
            presets.append(dict(rec=rec, per=per, fnum=n.fnum, block=n.block))
        if n.tl != s["lvl"]:
            b += bytes([0x01, n.tl])
            s["lvl"] = n.tl
        pair = (t0 - s["t"], max(1, t1 - t0))
        s["t"] = t0
        rc = s["rc"]
        if pair in rc:
            i = rc.index(pair)
            rc.pop(i)
        else:
            i = 3
        rc.insert(0, pair)
        del rc[3:]
        b.append(i << 6 | (0x20 if n.minor else 0) | (0x10 if bonus[id(n)] else 0))
        pi = pidx[key]
        b += bytes([pi]) if pi < 255 else bytes([255, pi >> 8, pi & 255])
        if i == 3:
            b += NUM(pair[0]) + NUM(pair[1])
    for v in range(6):
        if loop_t is not None and not st[v]["synced"]:
            loops[v] = len(streams[v])
            streams[v].append(0x02)
        streams[v].append(0x03)
    # header: loop tick ($ffff: none), end tick, 6 x (stream offset, loop offset)
    head = struct.pack(">HH", 0xFFFF if loop_t is None else loop_t, end_t)
    off = len(head) + 6 * 4
    body = bytearray()
    for v in range(6):
        head += struct.pack(">HH", off + len(body), off + len(body) + loops[v])
        body += streams[v]
    return bytes(head + body), presets


# ------------------------------------------------------------------ the player, modelled
ATT_VOL = [round(64 * 10 ** (-TL_DB * a / 20)) for a in range(128)]
QUIET = 53 * 256                    # (40 dB down: the channel is free)


class Player:
    """trk_play.s, tick by tick: the six voice streams read as their notes
    come; new notes given channels (the most important first: a free
    channel, a released one - the quietest -, else the channel of a lower
    priority note, unless a doubling / echo voice); a channel's note
    starts a tick after it is given it (Paula's DMA stopped, then started);
    volumes per tick from the sample's fades."""

    def __init__(self, tune, presets):
        self.d, self.presets = tune, presets
        self.loop_t, self.end_t = struct.unpack(">HH", tune[:4])
        self.voices = []
        for v in range(6):
            o, lo = struct.unpack(">HH", tune[4 + 4 * v:8 + 4 * v])
            self.voices.append(dict(p=o, lp=lo, t=0, rc=[], lvl=0, next=None, done=False))
            self.read(self.voices[-1])
        self.ch = [dict(on=False) for _ in range(NCH)]
        self.tick = self.pos = 0
        self.starts = []            # (tick, channel, preset, level, key off tick)

    def num(self, v):
        x = self.d[v["p"]]
        v["p"] += 1
        if x & 0x80:
            x = (x & 0x7F) << 8 | self.d[v["p"]]
            v["p"] += 1
        return x

    def read(self, v):
        """The voice's next note -> v["next"] (or done)."""
        while True:
            a = self.d[v["p"]]
            v["p"] += 1
            if a & 15 == 1:
                v["lvl"] = self.d[v["p"]]
                v["p"] += 1
            elif a & 15 == 2:
                v["t"], v["rc"] = (self.loop_t, [])
            elif a & 15 == 3:
                v["done"], v["next"] = True, None
                return
            else:
                pr = self.d[v["p"]]
                v["p"] += 1
                if pr == 255:
                    pr = self.d[v["p"]] << 8 | self.d[v["p"] + 1]
                    v["p"] += 2
                i = a >> 6
                if i == 3:
                    pair = (self.num(v), self.num(v))
                else:
                    pair = v["rc"].pop(i)
                v["rc"].insert(0, pair)
                del v["rc"][3:]
                t0 = v["t"] + pair[0]
                v["t"] = t0
                v["next"] = dict(t0=t0, t1=t0 + pair[1], pre=pr, lvl=v["lvl"], minor=bool(a & 0x20),
                                 pri=127 - v["lvl"] + (8 if a & 0x10 else 0))
                return

    def step(self):
        """One tick: self.pos is the time in the tune (the loop goes back),
        self.tick the time for the channels."""
        t = self.tick
        if self.loop_t != 0xFFFF and self.pos == self.end_t:     # loop: every voice from its sync
            self.pos = self.loop_t
            for v in self.voices:
                v["p"], v["done"] = v["lp"], False
                self.read(v)
        # channels given a note last tick start now; envelopes
        for c, ch in enumerate(self.ch):
            if ch.get("pending"):
                ch.update(ch.pop("pending"))
                ch["on"], ch["start"], ch["rel"], ch["faded"] = True, t, 0, 0
                ch["t1"] = t + ch["dur"]
                self.starts.append((t, c, ch["pre"], ch["lvl"], ch["t1"]))
            elif ch["on"]:
                pre = self.presets[ch["pre"]]
                rec = pre["rec"]
                if t >= ch["t1"]:
                    ch["rel"] += rec["rel"][pre["block"]]
                elif rec["loop"] is not None and t - ch["start"] >= ch["loopt"]:
                    if ch["faded"] < rec["total1"]:
                        st = eg_step(rec["dr"], pre["fnum"], pre["block"])
                        ch["faded"] += st
                    else:
                        st = eg_step(rec["sr"], pre["fnum"], pre["block"])
                    ch["rel"] += st
                ch["rel"] = min(ch["rel"], 32767)
                if rec["loop"] is None and t - ch["start"] >= ch["endt"]:
                    ch["on"] = False
        # new notes
        new = []
        for v in self.voices:
            while v["next"] is not None and v["next"]["t0"] == self.pos:
                new.append(v["next"])
                self.read(v)
        for n in sorted(new, key=lambda n: -n["pri"]):
            c = self.choose(n)
            if c is None:
                continue
            pre = self.presets[n["pre"]]
            rec = pre["rec"]
            pr = PAL / pre["per"]
            self.ch[c]["on"] = False
            self.ch[c]["pending"] = dict(pre=n["pre"], lvl=n["lvl"], dur=n["t1"] - n["t0"], pri=n["pri"],
                                         loopt=0 if rec["loop"] is None else
                                         (rec["loop"] // 2) * pre["per"] // TICKDIV,
                                         endt=min(65535, (len(rec["data"]) // 2) * pre["per"] // TICKDIV))
        self.tick += 1
        self.pos += 1

    def choose(self, n):
        t = self.tick
        busy = lambda ch: bool(ch.get("pending")) or (ch["on"] and not (t >= ch["t1"] and ch["rel"] >= QUIET))
        free = [c for c, ch in enumerate(self.ch) if not busy(ch)]
        if free:
            return free[0]
        rel = [c for c, ch in enumerate(self.ch) if not ch.get("pending") and t >= ch["t1"]]
        if rel:
            return max(rel, key=lambda c: self.ch[c]["rel"])
        if n["minor"]:
            return None
        c = min(range(NCH), key=lambda c: (self.ch[c].get("pending") or self.ch[c])["pri"])
        if (self.ch[c].get("pending") or self.ch[c])["pri"] < n["pri"]:
            return c
        return None


def render_player(pl, seconds, rate=28000):
    """Run the model for `seconds`; the four channels as Paula plays them -> (L, R)."""
    nt = int(seconds / TICK)
    tpr = TICK * rate
    nout = int(seconds * rate)
    out = np.zeros((NCH, nout))
    pos = [0.0] * NCH
    for k in range(nt):
        pl.step()
        a, b = int(k * tpr), min(int((k + 1) * tpr), nout)
        for c, ch in enumerate(pl.ch):
            if not ch["on"] or b <= a:
                continue
            pre = pl.presets[ch["pre"]]
            rec, per = pre["rec"], pre["per"]
            if ch["start"] == pl.tick - 1:
                pos[c] = 0.0
            stepv = PAL / per / rate
            idx = (pos[c] + stepv * np.arange(b - a)).astype(int)
            pos[c] += stepv * (b - a)
            data, loop = rec["data"], rec["loop"]
            L = len(data)
            if loop is None:
                vals = np.where(idx < L, data[np.minimum(idx, L - 1)], 0)
            else:
                ll = L - loop
                vals = data[np.where(idx >= L, loop + (idx - loop) % ll, idx)]
            if EXACT_ENV:               # (analysis: the prototype's exact envelope)
                import importlib.util
                global _conv
                if "_conv" not in globals():
                    spec = importlib.util.spec_from_file_location("conv", os.environ["BT_CONV"])
                    _conv = importlib.util.module_from_spec(spec)
                    src = open(os.environ["BT_CONV"]).read().split("def main")[0]
                    exec(compile(src, "conv", "exec"), _conv.__dict__)
                tt = (pl.tick - 1 - ch["start"]) * TICK
                base = rec["base"]
                g = _conv.env_curve(base, pre["fnum"], pre["block"], (ch["t1"] - ch["start"]) * TICK, np.array([tt]))[0]
                fr, br = model.Sample.note(rec["f_ref"])
                tau = tt * (PAL / per) / SRATE
                if rec["loop"] is not None:
                    tau = min(tau, rec["loop"] / SRATE)
                gs = _conv.env_curve(base, fr, br, 1e9, np.array([tau]))[0]
                ratio = g / gs if gs > 1e-4 else 0.0
                at = ch["lvl"] + rec["att"]
                vol = min(64, ATT_VOL[at] * ratio) if at < 128 else 0
            else:
                at = ch["lvl"] + rec["att"] + (ch["rel"] >> 8)
                vol = ATT_VOL[at] if at < 128 else 0
            out[c, a:b] = vals / 127 * vol / 64
    if NCH != 4:
        return out.sum(axis=0), out.sum(axis=0)
    return out[0] + out[3], out[1] + out[2]


# ------------------------------------------------------------------ the tunes
def convert(logs, budget=BUDGET, log=print):
    """-> (inst, {cmd: (tune bytes, presets)})"""
    tunes = {}
    for c in sorted(logs):
        _, ls, end = span(c)
        tunes[c] = (notes_of(logs[c], end + 0.5), ls, end)
    inst = Instruments([n for ns, _, _ in tunes.values() for n in ns])
    for c, (ns, _, _) in tunes.items():
        mark_minor(ns)
        set_priorities(ns)
    # singles first, then the combinations that save the most per byte
    wants_all = {}
    for c, (ns, ls, end) in tunes.items():
        out, wants = allocate(ns, inst, set())
        for n in ns:
            inst.get(_single(n))
        for ik, (cnt, tmp) in wants.items():
            w = wants_all.setdefault(ik, [0, tmp])
            w[0] += cnt
    singles = sum(inst.size(ik) for ik in inst.order)
    est = {}
    for ik, (cnt, tmp) in wants_all.items():
        base = inst.cache.get(inst.ikey(_single(tmp)))
        est[ik] = (len(base["data"]) if base else 2048) + 900
    accepted, used = set(), 0
    for ik in sorted(wants_all, key=lambda k: -wants_all[k][0] / est[k]):
        if wants_all[ik][0] < 3 or used + est[ik] > budget:
            continue
        accepted.add(ik)
        used += est[ik]
    result = {}
    for c, (ns, ls, end) in tunes.items():
        fresh = notes_of(logs[c], end + 0.5)
        mark_minor(fresh)
        set_priorities(fresh)
        fin = final_notes(fresh, inst, accepted)
        result[c] = encode(fin, inst, ls, end)
    used_ik = {id(p["rec"]) for _, presets in result.values() for p in presets}
    keep = [ik for ik in inst.order if id(inst.cache[ik]) in used_ik]
    top = max(inst.cache[ik]["peak"] for ik in keep)
    for ik in keep:                     # loudness: TL steps below the loudest sample
        inst.cache[ik]["att"] = max(0, round(20 * math.log10(top / inst.cache[ik]["peak"]) / TL_DB))
    mem = sum(inst.size(ik) for ik in keep)
    log("music: %d samples, %.1f KB (%d of them combined: %.1f KB)" % (
        len(keep), mem / 1024, sum(1 for ik in keep if len(ik) > 2),
        sum(inst.size(ik) for ik in keep if len(ik) > 2) / 1024))
    return inst, result


def _single(n):
    t = Note()
    t.__dict__.update(n.__dict__)
    t.parts = n.parts[:1]
    return t


def load_logs():
    cache = os.path.join(sound_check.B, "tunes.pickle")
    src = [os.path.join(ROOT, f) for f in ("data/sound_entries.txt", "src/sound.s", "tools/z80/translate.py")]
    if os.path.exists(cache) and all(os.path.getmtime(cache) > os.path.getmtime(f) for f in src):
        logs = pickle.load(open(cache, "rb"))
        if set(logs) >= set(TUNES):
            return logs
    logs = capture(sorted(TUNES))
    pickle.dump(logs, open(cache, "wb"))
    return logs


def main():
    if sys.argv[1] == "--wav":
        outd = sys.argv[2]
        cmds = [int(x, 16) for x in sys.argv[3:]] or sorted(TUNES)
        os.makedirs(outd, exist_ok=True)
        inst, result = convert(load_logs())
        for c in cmds:
            tune, presets = result[c]
            pl = Player(tune, presets)
            L, R = render_player(pl, min(span(c)[2], 45))
            data = np.stack([L, R], axis=1).reshape(-1)
            data = np.clip(data / max(np.abs(data).max(), 1e-9) * 0.9, -1, 1)
            f = wave.open(os.path.join(outd, "trk_%02x.wav" % c), "wb")
            f.setnchannels(2)
            f.setsampwidth(2)
            f.setframerate(28000)
            f.writeframes((data * 30000).astype("<i2").tobytes())
            f.close()
            print("%02x: %d bytes of notes, %d presets, %d notes started" % (c, len(tune), len(presets), len(pl.starts)))
        return
    out, inc = sys.argv[1], sys.argv[2]
    inst, result = convert(load_logs())
    write_bank(out, inc, inst, result)


# The bank (src/trk_play.s), big-endian, all in chip RAM:
#   +0     w   samples
#   +2     w   the largest tune's streams, unpacked (trk_play.s's buffer)
#   +4     32 x l  tunes: commands $20-$3F, offset from the bank (0: none)
#   +132   samples x TS_SIZE: data offset (l), length (words), loop start
#          (words, $ffff: none), loop length (words), decay (rate code),
#          its total (1/256 TL steps), sustain (rate code), loudness (TL
#          steps, a byte), (a byte), release per block (8 words)
#   then the tunes: loop tick ($ffff: none), end tick, 6 x (stream, loop:
#   offsets in the streams), presets (w), (w), presets x TP_SIZE: sample,
#   period, block, key code; the streams, packed (tools/lzpack.py); then
#   the samples' data (words)
TS_SIZE = 36
TP_SIZE = 6
TICKDIV = round(PAL * TICK / 2)     # ticks = words * period / TICKDIV (trk_play.s)


def write_bank(out, inc, inst, result):
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    import lzpack
    samples = []
    sidx = {}
    for c in sorted(result):
        for p in result[c][1]:
            if id(p["rec"]) not in sidx:
                sidx[id(p["rec"])] = len(samples)
                samples.append(p["rec"])
    head_size = 4 + 32 * 4 + len(samples) * TS_SIZE
    tunes = bytearray()
    toff = [0] * 32
    biggest = 0
    for c in sorted(result):
        tune, presets = result[c]
        toff[c - 0x20] = head_size + len(tunes)
        so = struct.unpack(">2H" + "HH" * 6, tune[:28])
        streams = tune[28:]
        biggest = max(biggest, len(streams))
        hdr = struct.pack(">2H" + "HH" * 6, so[0], so[1], *[x - 28 for x in so[2:]])
        pre = bytearray(struct.pack(">HH", len(presets), 0))
        for p in presets:
            pre += struct.pack(">HHBB", sidx[id(p["rec"])], p["per"], p["block"],
                               opn.keycode(p["fnum"], p["block"]))
        tunes += hdr + pre + lzpack.pack(bytes(streams))
        if len(tunes) & 1:
            tunes.append(0)
    data = bytearray()
    recs = bytearray()
    base = head_size + len(tunes)
    for rec in samples:
        q = rec["data"]
        off = base + len(data)
        data += bytes(int(v) & 0xFF for v in q)
        loop = rec["loop"]
        recs += struct.pack(">IHHHHHHBB8HH", off, len(q) // 2, 0xFFFF if loop is None else loop // 2,
                            0 if loop is None else (len(q) - loop) // 2, rec["dr"], rec["total1"], rec["sr"],
                            min(127, rec["att"]), 0, *rec["rel"], 0)
    assert len(recs) == len(samples) * TS_SIZE
    blob = struct.pack(">HH", len(samples), biggest) + b"".join(struct.pack(">I", x) for x in toff) + recs + \
        tunes + data
    open(out, "wb").write(blob)
    open(inc, "w").write("TRK_SIZE\tequ\t%d\t\t; (tools/sound/tracker.py)\nTRK_BUF\tequ\t%d\n"
                         "TRK_TICK\tequ\t%d\nTRK_TICKDIV\tequ\t%d\n" %
                         (len(blob), (biggest + 3) & -4, TICK_CIA, TICKDIV))
    print("%s: %d samples (%.1f KB), %d tunes (%.1f KB of notes, packed), %.1f KB in all, %d byte buffer" % (
        out, len(samples), len(data) / 1024, len(result), len(tunes) / 1024, len(blob) / 1024, biggest))


if __name__ == "__main__":
    main()
