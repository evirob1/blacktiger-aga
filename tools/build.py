"""Build the Black Tiger AGA disk images from your own MAME ROM set.

usage:  python tools/build.py [--roms roms/blktiger.zip] [--level N] [--test X Y]

Needs Python 3 (standard library only) and vasmm68k_mot on the PATH
(or set the VASM environment variable to its full path).
Output: build/viewer_levelN.adf  (one per level; all 8 by default)
"""
import argparse
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

BSS = 300000


def vasm():
    exe = os.environ.get("VASM") or shutil.which("vasmm68k_mot") or shutil.which("vasmm68k_mot.exe")
    if not exe:
        raise SystemExit("vasmm68k_mot not found - put it on your PATH or set VASM=path\\to\\vasmm68k_mot.exe")
    return exe


def assemble(src, out, incdir=None, defines=(), extra=()):
    cmd = [vasm(), "-quiet", "-Fbin", "-m68020", "-o", out] + list(extra)
    if incdir:
        cmd.append("-I" + incdir)
    cmd += ["-D%s=%s" % d for d in defines]
    cmd.append(src)
    subprocess.run(cmd, check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--roms", default=os.path.join(ROOT, "roms", "blktiger.zip"))
    ap.add_argument("--level", type=int, choices=range(1, 9))
    ap.add_argument("--test", nargs=2, type=int, metavar=("X", "Y"),
                    help="fixed view position (for screenshot tests)")
    a = ap.parse_args()

    build = os.path.join(ROOT, "build")
    os.makedirs(build, exist_ok=True)
    boot = os.path.join(build, "boot.bin")
    assemble(os.path.join(ROOT, "src", "boot.s"), boot)

    import convert_level
    import mkadf
    for level in ([a.level] if a.level else range(1, 9)):
        ldir = os.path.join(build, "level%d" % level)
        convert_level.convert(a.roms, level, ldir)
        payload = os.path.join(ldir, "viewer.bin")
        defines = [("TEST_X", a.test[0]), ("TEST_Y", a.test[1])] if a.test else []
        assemble(os.path.join(ROOT, "src", "viewer.s"), payload, ldir, defines)
        name = "test_view.adf" if a.test else "viewer_level%d.adf" % level
        mkadf.build(boot, payload, BSS, os.path.join(build, name))


if __name__ == "__main__":
    main()
