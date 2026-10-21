"""Check the FM synthesiser (src/fm_synth.s) against MAME: a log of YM2203
writes (MAME's, analysis/sound/ym_ref.txt: "W units chip register value
seconds") played through it in its test build (src/fm_test.s on
tools/harness/sound_sim.c), its output compared with MAME's recording of the
same (tools/sound/compare.py).

usage: python3 tools/sound/fm_check.py analysis/sound/ym_ref.txt seconds out.wav [ref.wav]
"""
import os
import subprocess
import sys
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "tools", "harness"))
import build  # noqa: E402  (vasm helper)
import sound_check  # noqa: E402  (Musashi)

UNITS = 3579545 / 72            # YM timer units per second
RATE = 3546895 / 256            # the synth's output (PAL Paula, period 256)
B = os.path.join(ROOT, "build", "sound")
BURST = 0.0005                  # writes closer than this: one interrupt routine's


def main():
    log, seconds, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
    os.makedirs(B, exist_ok=True)
    with open(os.path.join(B, "fm_events.s"), "w") as f:
        f.write("fm_events:\n")
        last = burst = -1
        for line in open(log):
            w = line.split()
            if len(w) < 6 or w[0] != "W":
                continue
            t = float(w[5])
            if t >= seconds:
                break
            if t - last > BURST:        # (a burst of writes: one interrupt's, at once)
                burst = t
            last = t
            f.write("\tdc.l\t%d,$%x\n" % (round(burst * UNITS * 256),
                                          (int(w[2]) & 1) << 16 | int(w[3], 16) << 8 | int(w[4], 16)))
        f.write("\tdc.l\t%d,0\n\tdc.l\t-1\n" % round(seconds * UNITS * 256))
    sound_check.run([build.vasm(), "-quiet", "-Fbin", "-m68040", "-Isrc", "-I" + B, "-o",
                     os.path.join(B, "fm_test.bin"), "src/fm_test.s"])
    m = sound_check.musashi()
    sound_check.run(["gcc", "-O2", "-w", "-I" + m, "-o", os.path.join(B, "sound_sim"),
                     "tools/harness/sound_sim.c", m + "/m68kcpu.c", m + "/m68kops.c", m + "/m68kdasm.c",
                     m + "/softfloat/softfloat.c", "-lm"])
    pcm = os.path.join(B, "fm_test.pcm")
    r = subprocess.run([os.path.join(B, "sound_sim"), os.path.join(B, "fm_test.bin")],
                       env=dict(os.environ, SND_PCM=pcm), capture_output=True, text=True)
    print(r.stdout.strip()[-300:])
    data = open(pcm, "rb").read()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(round(RATE))
        w.writeframes(data)
    print("%d samples (%.1f s)" % (len(data) // 2, len(data) / 2 / RATE))
    if len(sys.argv) > 4:
        subprocess.run([sys.executable, os.path.join(ROOT, "tools", "sound", "compare.py"), sys.argv[4], "0",
                        out, "0"], check=True)


if __name__ == "__main__":
    main()
