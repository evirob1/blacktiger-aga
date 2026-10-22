"""Where the build's helpers are: the Python scripts it runs as processes of
their own, and the programs it uses (vasm, the sound program's 68k emulator,
ymfm's renderer).

From a source checkout they are found as before (on the PATH, or built from
source with gcc / g++ / git). In the one-file builder (tools/make_disk.py,
packed by tools/package/build_builder.py) they come with it, ready built.
"""
import os
import shutil
import sys

FROZEN = getattr(sys, "frozen", False)
BUNDLE = getattr(sys, "_MEIPASS", None)
EXE = ".exe" if os.name == "nt" else ""


def python(script):
    """The command that runs a Python script in a process of its own."""
    if FROZEN:
        return [sys.executable, "--script", script]
    return [sys.executable, script]


def bundled(name):
    """A program that came with the builder (bin/), or None."""
    if BUNDLE:
        p = os.path.join(BUNDLE, "bin", name + EXE)
        if os.path.exists(p):
            return p
    p = os.environ.get("BT_TOOLS")
    if p and os.path.exists(os.path.join(p, name + EXE)):
        return os.path.join(p, name + EXE)
    return None


def vasm():
    exe = (os.environ.get("VASM") or bundled("vasmm68k_mot") or shutil.which("vasmm68k_mot")
           or shutil.which("vasmm68k_mot.exe"))
    if not exe:
        raise SystemExit("vasmm68k_mot not found - put it on your PATH or set VASM=path\\to\\vasmm68k_mot.exe")
    return exe
