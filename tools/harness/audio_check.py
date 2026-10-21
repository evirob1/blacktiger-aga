"""Check that every Paula channel plays: a minute of play (fast RAM, coin, start, a
random joystick) on build/amiga_sim, each channel recorded on its own
(BT_WAVSOLO), its level per 10 seconds. Fails if a channel stays silent once
the game has started (channel 0: FM chip 1, 1: FM chip 2, 2 / 3: the SSGs).

usage: python3 tools/harness/audio_check.py [seconds]   (after tools/harness/amiga_sim.sh 0)
"""
import os
import subprocess
import sys
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "build", "audio_check")


def level(path):
    """Mean absolute sample (both sides) per 10 seconds."""
    w = wave.open(path)
    rate, n = w.getframerate(), w.getnframes()
    data = w.readframes(n)
    out = []
    for s in range(0, n - rate * 10 + 1, rate * 10):
        chunk = data[s * 4:(s + rate * 10) * 4]
        total = 0
        for i in range(0, len(chunk), 2):
            total += abs(int.from_bytes(chunk[i:i + 2], "little", signed=True))
        out.append(total // (len(chunk) // 2))
    return out


def main():
    secs = int(sys.argv[1]) if len(sys.argv) > 1 else 60
    os.makedirs(OUT, exist_ok=True)
    env = dict(os.environ)
    out = subprocess.run(["bash", "-c", "source tools/harness/sim_env.sh; env"], cwd=ROOT,
                         capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        if line.startswith("BT_") and "=" in line:
            k, v = line.split("=", 1)
            env[k] = v
    env.update(BT_KEYS="300:05,310:-05,400:01,410:-01", BT_RANDJOY="7",
               BT_FASTMODE="1")         # (fast RAM: music and effects)
    procs = []
    for c in range(4):
        e = dict(env, BT_WAVSOLO=str(c), BT_WAV=os.path.join(OUT, "ch%d.wav" % c))
        procs.append(subprocess.Popen([os.path.join(ROOT, "build", "amiga_sim"),
                                       os.path.join(ROOT, "build", "game", "game.bin"), str(secs)],
                                      cwd=ROOT, env=e, stdout=subprocess.DEVNULL))
    for p in procs:
        p.wait()
    bad = 0
    for c in range(4):
        lv = level(os.path.join(OUT, "ch%d.wav" % c))
        print("channel %d, level per 10 s: %s" % (c, " ".join("%5d" % x for x in lv)))
        if not any(lv[2:]):
            bad += 1
    print("every channel plays" if not bad else "%d channel(s) silent" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
