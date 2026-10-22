"""ymfm - MAME's YM2203 emulation (Aaron Giles, BSD licence; fetched with git,
built with g++ into tools/sound/ym_render.cpp's renderer) - for the build:
rendering register writes, resampling the result.
"""
import os
import subprocess
import sys
import tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
CLOCK = 3579545
RATE = CLOCK / 24                       # ym_render's output (OPN_FIDELITY_MIN)
OPERATOR_BASES = (0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90)


def renderer():
    """ymfm (git) and tools/sound/ym_render.cpp (g++) -> the renderer's path
    (or the one-file builder's, ready built)."""
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    import toolpaths
    if toolpaths.bundled("ym_render"):
        return toolpaths.bundled("ym_render")
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


def render(writes, seconds):
    """writes: [(seconds, chip, register, value)] -> (fm, ssg) at RATE."""
    with tempfile.TemporaryDirectory() as d:
        log, fm, ssg = (os.path.join(d, n) for n in ("log.txt", "fm.f32", "ssg.f32"))
        with open(log, "w") as f:
            for t, c, r, v in writes:
                f.write("%.6f %d %x %x\n" % (t, c, r, v))
        subprocess.run([renderer(), log, str(seconds), fm, ssg], check=True, stderr=subprocess.DEVNULL)
        return (np.fromfile(fm, dtype=np.float32).astype(float),
                np.fromfile(ssg, dtype=np.float32).astype(float))


def note(patch, fnum, block, seconds):
    """One note of a patch ({register base: [slots 1-4]}, as
    tools/sound/opn.py's patch_regs; 0xB0: feedback / algorithm) on FM
    channel 0, keyed on at once -> FM at RATE."""
    w = [(0, 0, 0x27, 0)]
    for base in OPERATOR_BASES:
        for k, s in enumerate((0, 2, 1, 3)):        # (registers: slots 1, 3, 2, 4)
            w.append((0, 0, base + 4 * k, patch[base][s]))
    w += [(0, 0, 0xB0, patch[0xB0]), (0, 0, 0xA4, block << 3 | fnum >> 8), (0, 0, 0xA0, fnum & 0xFF),
          (0.0001, 0, 0x28, 0xF0)]
    return render(w, seconds)[0]


def resample(x, rate, cutoff=0.45):
    """RATE -> rate: windowed-sinc low-pass at cutoff * rate, then linear."""
    fc = cutoff * rate / RATE
    n = np.arange(-400, 401)
    h = 2 * fc * np.sinc(2 * fc * n) * np.blackman(len(n))
    y = np.convolve(x, h / h.sum(), "same")
    pos = np.arange(0, len(y) - 1, RATE / rate)
    i = pos.astype(int)
    return y[i] + (y[i + 1] - y[i]) * (pos - i)
