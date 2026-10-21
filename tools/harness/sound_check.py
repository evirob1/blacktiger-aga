"""Check the translated sound program against MAME: replay the command latch
writes, resets and timer interrupts of a MAME log (tools/mame/sound_log.lua,
with time stamps) in the test build (src/sound_test.s on
tools/harness/sound_sim.c) and compare the YM2203 writes, in order. (The
timers themselves, modelled in src/sound.s, only set the tempo: here the
interrupts come when they did in MAME.)

usage: python3 tools/harness/sound_check.py analysis/sound/ym_check.txt [--modelled STEP]

--modelled STEP: the timers as modelled (src/sound.s), run STEP units at a
time as the player does (a chunk: about 517), with only the latch writes and
resets from MAME: checks the tempo - when the key-ons come, against MAME.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import bt_rom  # noqa: E402
import build  # noqa: E402  (vasm helper)

UNITS = 3579545 / 72            # YM timer units per second
B = os.path.join(ROOT, "build", "sound")


def run(cmd, **kw):
    subprocess.run(cmd, check=True, cwd=ROOT, **kw)


def musashi():
    """The Musashi 68k emulator's source (fetched with git, its opcode tables
    generated with gcc, as tools/harness/build.sh does)."""
    m = os.path.join(ROOT, "build", "musashi")
    if not os.path.exists(os.path.join(m, "m68kcpu.c")):
        run(["git", "clone", "-q", "--depth", "1", "https://github.com/kstenerud/Musashi.git", m])
    if not os.path.exists(os.path.join(m, "m68kops.c")):
        run(["gcc", "-O2", "-o", os.path.join(m, "m68kmake"), os.path.join(m, "m68kmake.c")])
        subprocess.run([os.path.join(m, "m68kmake"), ".", "m68k_in.c"], check=True, cwd=m,
                       stdout=subprocess.DEVNULL)
    return m


def simulate():
    """Translate the sound program, build the test (build/sound/sound_events.s
    written already) and run it: its output lines."""
    os.makedirs(B, exist_ok=True)
    rom = bt_rom.load_roms(os.path.join(ROOT, "roms", "blktiger.zip"))["audiocpu"]
    open(os.path.join(B, "snd_rom.bin"), "wb").write(rom)
    run([sys.executable, "tools/z80/translate.py", "roms/blktiger.zip", "data/sound_entries.txt",
         os.path.join(B, "sound_code.s"), os.path.join(B, "report.txt"), "--sound"])
    run([build.vasm(), "-quiet", "-Fbin", "-m68020", "-Isrc", "-I" + B, "-o",
         os.path.join(B, "sound_test.bin"), "src/sound_test.s"])
    m = musashi()
    run(["gcc", "-O2", "-w", "-I" + m, "-o", os.path.join(B, "sound_sim"), "tools/harness/sound_sim.c",
         m + "/m68kcpu.c", m + "/m68kops.c", m + "/m68kdasm.c", m + "/softfloat/softfloat.c", "-lm"])
    return subprocess.run([os.path.join(B, "sound_sim"), os.path.join(B, "sound_test.bin")],
                          capture_output=True, text=True).stdout.splitlines()


def main():
    log = sys.argv[1]
    step = int(sys.argv[3]) if len(sys.argv) > 3 and sys.argv[2] == "--modelled" else 0
    os.makedirs(B, exist_ok=True)
    # events: latch writes, resets, and the timer interrupts as MAME ran them
    # (each interrupt's first write: reg $24 = timer A's, $26 = timer B's; the
    # first of each after a reset is the start-up's own)
    # (the interrupt reads the latch about 25 us after acknowledging its
    # timer, register $27: its time here is just before that)
    mame, events, first, pending = [], [], {"24": True, "26": True}, None
    for line in open(log):
        f = line.split()
        if f[0] == "W":
            mame.append((int(f[2]), int(f[3], 16), int(f[4], 16), float(f[5])))
            if f[2] == "0" and f[3] in first:
                if first[f[3]]:
                    first[f[3]] = False
                else:
                    pending = 0x200 if f[3] == "24" else 0x201
            elif f[2] == "0" and f[3] == "27" and pending is not None and not step:
                events.append((float(f[5]) + 20e-6, pending))   # (~ when it reads the latch)
                pending = None
        elif f[0] == "L":
            events.append((float(f[3]), int(f[2], 16)))
        elif f[0] == "R":                       # reset on / off: $101 / $100
            events.append((float(f[3]), 0x100 | int(f[2])))
            if f[2] == "0":
                first = {"24": True, "26": True}
    events.sort()
    with open(os.path.join(B, "sound_events.s"), "w") as o:
        o.write("snd_events:\n\tdc.l\t%d\n" % step)
        for t, v in events:
            o.write("\tdc.l\t%d,$%02x\n" % (round(t * UNITS), v))
        o.write("\tdc.l\t-1\n")
    out = simulate()
    ours = []
    for line in out:
        f = line.split()
        if f[0] == "W":
            ours.append((int(f[2]), int(f[3], 16), int(f[4], 16), int(f[1]) / UNITS))
        else:
            print(line)
    if step:
        return tempo(ours, mame)
    n = min(len(ours), len(mame))
    for i in range(n):
        if ours[i][:3] != mame[i][:3]:
            print("write %d differs: ours chip %d reg %02x = %02x at %.4f s, MAME chip %d reg %02x = %02x at %.4f s"
                  % ((i,) + ours[i] + mame[i]))
            for j in range(max(0, i - 3), min(n, i + 4)):
                print("  %6d ours %d %02x %02x %.4f   MAME %d %02x %02x %.4f" % ((j,) + ours[j] + mame[j]))
            return 1
    worst = max((abs(ours[i][3] - mame[i][3]) for i in range(n)), default=0)
    print("%d of %d YM writes matched MAME in order (MAME logged %d); timing within %.1f ms"
          % (n, len(ours), len(mame), worst * 1000))
    return 0


def tempo(ours, mame):
    """Key-ons (register $28, slots on) in order: how far ours drift from MAME's."""
    for nm, w in (("ours", ours), ("MAME", mame)):
        print("%s: %d timer A writes ($24), %d timer B ($26), %d acknowledges ($27) up to %.1f s" % (
            nm, sum(1 for x in w if x[0] == 0 and x[1] == 0x24 and x[3] < 56),
            sum(1 for x in w if x[0] == 0 and x[1] == 0x26 and x[3] < 56),
            sum(1 for x in w if x[0] == 0 and x[1] == 0x27 and x[3] < 56), 56))

    def keyons(w):
        return [(c, v, t) for c, r, v, t in w if r == 0x28 and v >> 4]
    a, b = keyons(ours), keyons(mame)
    n = 0
    while n < min(len(a), len(b)) and a[n][:2] == b[n][:2]:
        n += 1
    d = sorted(x[2] - y[2] for x, y in zip(a[:n], b[:n]))
    print("%d key-ons (MAME %d), the first %d in the same order" % (len(a), len(b), n))
    if n:
        print("time against MAME's: median %+.1f ms, from %+.1f to %+.1f ms" %
              (1000 * d[n // 2], 1000 * d[0], 1000 * d[-1]))
    if n < min(len(a), len(b)):
        print("then ours %s at %.4f s, MAME's %s at %.4f s" % (a[n][:2], a[n][2], b[n][:2], b[n][2]))
    for i in range(0, n, max(1, n // 12)):
        print("  key-on %4d: ours %8.3f s, MAME %8.3f s" % (i, a[i][2], b[i][2]))
    span = (a[-1][2] - a[0][2]) / max(b[-1][2] - b[0][2], 1e-9) if a and b else 0
    print("from first to last key-on: %.3f x MAME's time" % span)
    return 0


if __name__ == "__main__":
    sys.exit(main())
