"""Compare two recordings of the same music (e.g. MAME's -wavwrite output and
tools/sound/model.py's): per 0.1 s window, the correlation of their spectra
in semitone bands (are the same notes playing?) and of their loudness.

usage: python3 tools/sound/compare.py ref.wav from_s ours.wav [ours_from_s]
"""
import sys
import wave

import numpy as np

WIN = 0.1


def load(path, start, secs):
    w = wave.open(path)
    rate, ch = w.getframerate(), w.getnchannels()
    w.setpos(int(start * rate))
    raw = np.frombuffer(w.readframes(int(secs * rate)), dtype="<i2").astype(float)
    data = raw.reshape(-1, ch).mean(axis=1) / 32768
    return data, rate


def bands(data, rate):
    """Semitone band energies (MIDI notes 28-108) per window."""
    n = int(WIN * rate)
    fft_n = 1 << int(np.ceil(np.log2(n * 4)))
    freqs = np.fft.rfftfreq(fft_n, 1 / rate)
    note = 69 + 12 * np.log2(np.maximum(freqs, 1) / 440)
    out = []
    for i in range(0, len(data) - n, n):
        spec = np.abs(np.fft.rfft(data[i:i + n] * np.hanning(n), fft_n)) ** 2
        b = np.bincount(np.clip(np.round(note).astype(int), 0, 127), spec, minlength=128)[28:109]
        out.append(b)
    return np.array(out)


def main():
    ref_path, ref_t, ours_path = sys.argv[1], float(sys.argv[2]), sys.argv[3]
    ours_t = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0
    w = wave.open(ours_path)
    secs = w.getnframes() / w.getframerate() - ours_t
    a, ra = load(ref_path, ref_t, secs)
    b, rb = load(ours_path, ours_t, secs)
    A, B = bands(a, ra), bands(b, rb)
    n = min(len(A), len(B))
    A, B = A[:n], B[:n]
    corr = []
    for x, y in zip(np.log1p(A * 1e4), np.log1p(B * 1e4)):
        if x.std() > 0 and y.std() > 0:
            corr.append(np.corrcoef(x, y)[0, 1])
    la, lb = np.log(A.sum(axis=1) + 1e-9), np.log(B.sum(axis=1) + 1e-9)
    print("spectra (semitone bands): mean correlation %.2f over %d windows (10%% worst %.2f)" %
          (np.mean(corr), len(corr), np.percentile(corr, 10)))
    print("loudness: correlation %.2f; level %+.1f dB" %
          (np.corrcoef(la, lb)[0, 1], 10 * np.log10(B.sum() / max(A.sum(), 1e-12))))
    # where the energy is: the strongest band per window, compared
    pa, pb = A.argmax(axis=1), B.argmax(axis=1)
    same = np.mean((pa - pb) % 12 == 0)
    print("strongest note class agrees in %.0f%% of windows (exact note %.0f%%)" %
          (100 * same, 100 * np.mean(pa == pb)))


if __name__ == "__main__":
    main()
