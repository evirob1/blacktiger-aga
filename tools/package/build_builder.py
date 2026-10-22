"""Pack the disk builder (tools/make_disk.py) into one program for this OS,
with what the build needs ready built inside it: vasm (the assembler, from
its source), the sound program's 68k emulator (Musashi + tools/harness/
sound_sim.c) and ymfm's renderer (tools/sound/ym_render.cpp). Nothing of the
game's ROMs goes in: the program makes the disk from the user's ROM set.

Needs: Python 3 with numpy and pyinstaller, a C / C++ compiler (gcc, g++;
on Windows MinGW), make, git and network access (the sources).

usage: python tools/package/build_builder.py   ->  dist/make_disk[.exe]
"""
import glob
import os
import shutil
import subprocess
import sys
import tarfile
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
WORK = os.path.join(ROOT, "build", "package")
BIN = os.path.join(WORK, "bin")
EXE = ".exe" if os.name == "nt" else ""
VASM_URL = "http://sun.hasenbraten.de/vasm/release/vasm.tar.gz"


def run(cmd, **kw):
    print("+", " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    if r.returncode:
        tail = (r.stdout + r.stderr).strip().splitlines()[-8:]
        raise RuntimeError("%s failed (%d): %s" % (" ".join(cmd[:3]), r.returncode, " | ".join(tail)))


def vasm():
    src = os.path.join(WORK, "vasm")
    if not os.path.exists(os.path.join(src, "Makefile")):
        tgz = os.path.join(WORK, "vasm.tar.gz")
        try:
            urllib.request.urlretrieve(VASM_URL, tgz)
        except OSError as e:                # (no network: the one installed, if any)
            have = shutil.which("vasmm68k_mot" + EXE)
            if not have:
                raise
            print("vasm source not reachable (%s): using %s" % (e, have))
            shutil.copy(have, BIN)
            return
        with tarfile.open(tgz) as t:
            t.extractall(WORK)
    run(["make", "CPU=m68k", "SYNTAX=mot"] + (["CC=gcc", "LD=gcc"] if os.name == "nt" else []), cwd=src)
    shutil.copy(os.path.join(src, "vasmm68k_mot" + EXE), BIN)


def sound_sim():
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    sys.path.insert(0, os.path.join(ROOT, "tools", "harness"))
    import sound_check
    m = sound_check.musashi()
    run(["gcc", "-O2", "-w", "-I" + m, "-o", os.path.join(BIN, "sound_sim" + EXE),
         os.path.join(ROOT, "tools", "harness", "sound_sim.c"), m + "/m68kcpu.c", m + "/m68kops.c",
         m + "/m68kdasm.c", m + "/softfloat/softfloat.c", "-lm"] + (["-static"] if os.name == "nt" else []))


def ym_render():
    y = os.path.join(ROOT, "build", "ymfm")
    if not os.path.exists(os.path.join(y, "src", "ymfm_opn.cpp")):
        run(["git", "clone", "-q", "--depth", "1", "https://github.com/aaronsgiles/ymfm.git", y])
    s = os.path.join(y, "src")
    run(["g++", "-O2", "-std=c++14", "-I" + s, "-o", os.path.join(BIN, "ym_render" + EXE),
         os.path.join(ROOT, "tools", "sound", "ym_render.cpp")] +
        [os.path.join(s, f) for f in ("ymfm_opn.cpp", "ymfm_ssg.cpp", "ymfm_misc.cpp", "ymfm_adpcm.cpp")] +
        (["-static"] if os.name == "nt" else []))


def main():
    os.makedirs(BIN, exist_ok=True)
    vasm()
    sound_sim()
    ym_render()
    sep = ";" if os.name == "nt" else ":"
    data = []
    for d in ("src", "data", "tools"):
        data += ["--add-data", os.path.join(ROOT, d) + sep + d]
    for b in glob.glob(os.path.join(BIN, "*")):
        data += ["--add-binary", b + sep + "bin"]
    # the build's scripts run from the bundle as files: what they import
    hidden = ["numpy", "argparse", "collections", "hashlib", "math", "pickle", "re", "struct",
              "subprocess", "tempfile", "wave", "zipfile", "zlib", "runpy", "shutil", "time"]
    run([sys.executable, "-m", "PyInstaller", "--onefile", "--console", "--name", "make_disk",
         "--distpath", os.path.join(ROOT, "dist"), "--workpath", os.path.join(WORK, "pyi"),
         "--specpath", WORK, "--paths", os.path.join(ROOT, "tools")] +
        sum((["--hidden-import", h] for h in hidden), []) + data +
        [os.path.join(ROOT, "tools", "make_disk.py")])
    print("\n->", os.path.join(ROOT, "dist", "make_disk" + EXE))


if __name__ == "__main__":
    try:
        main()
    except BaseException as e:              # (on GitHub: an annotation, readable without the log)
        if os.environ.get("GITHUB_ACTIONS"):
            import traceback
            last = traceback.format_exc().strip().splitlines()[-6:]
            print("::error title=build_builder::%s" % " | ".join(last).replace("%", "%25"))
        raise
