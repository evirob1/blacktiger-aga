"""Check the translated sound program against MAME: replay the command latch
writes, resets and timer interrupts of a MAME log (tools/mame/sound_log.lua,
with time stamps) in the test build (src/sound_test.s on
tools/harness/sound_sim.c) and compare the YM2203 writes, in order. (The
timers themselves, modelled in src/sound.s, only set the tempo: here the
interrupts come when they did in MAME.)

usage: python3 tools/harness/sound_check.py analysis/sound/ym_check.txt
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import bt_rom  # noqa: E402

UNITS = 3579545 / 72            # YM timer units per second
B = os.path.join(ROOT, "build", "sound")


def run(cmd, **kw):
    subprocess.run(cmd, check=True, cwd=ROOT, **kw)


def main():
    log = sys.argv[1]
    os.makedirs(B, exist_ok=True)
    # events: latch writes, resets, and the timer interrupts as MAME ran them
    # (each interrupt's first write: reg $24 = timer A's, $26 = timer B's; the
    # first of each after a reset is the start-up's own)
    # (the interrupt reads the latch after acknowledging its timer: its time
    # here is that of the acknowledge, register $27)
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
            elif f[2] == "0" and f[3] == "27" and pending is not None:
                events.append((float(f[5]) + 1e-7, pending))
                pending = None
        elif f[0] == "L":
            events.append((float(f[3]), int(f[2], 16)))
        elif f[0] == "R":                       # reset on / off: $101 / $100
            events.append((float(f[3]), 0x100 | int(f[2])))
            if f[2] == "0":
                first = {"24": True, "26": True}
    events.sort()
    with open(os.path.join(B, "sound_events.s"), "w") as o:
        o.write("snd_events:\n")
        for t, v in events:
            o.write("\tdc.l\t%d,$%02x\n" % (round(t * UNITS), v))
        o.write("\tdc.l\t-1\n")
    rom = bt_rom.load_roms(os.path.join(ROOT, "roms", "blktiger.zip"))["audiocpu"]
    open(os.path.join(B, "snd_rom.bin"), "wb").write(rom)
    run(["python3", "tools/z80/translate.py", "roms/blktiger.zip", "data/sound_entries.txt",
         os.path.join(B, "sound_code.s"), os.path.join(B, "report.txt"), "--sound"])
    run(["vasmm68k_mot", "-quiet", "-Fbin", "-m68020", "-Isrc", "-I" + B, "-o",
         os.path.join(B, "sound_test.bin"), "src/sound_test.s"])
    m = os.path.join(ROOT, "build", "musashi")
    run(["gcc", "-O2", "-w", "-I" + m, "-o", os.path.join(B, "sound_sim"), "tools/harness/sound_sim.c",
         m + "/m68kcpu.c", m + "/m68kops.c", m + "/m68kdasm.c", m + "/softfloat/softfloat.c", "-lm"])
    out = subprocess.run([os.path.join(B, "sound_sim"), os.path.join(B, "sound_test.bin")],
                         capture_output=True, text=True, check=True).stdout.splitlines()
    ours = []
    for line in out:
        f = line.split()
        if f[0] == "W":
            ours.append((int(f[2]), int(f[3], 16), int(f[4], 16), int(f[1]) / UNITS))
        else:
            print(line)
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


if __name__ == "__main__":
    sys.exit(main())
