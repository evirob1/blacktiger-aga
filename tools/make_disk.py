"""Black Tiger for the Amiga 1200: make the disk from your own arcade ROM set.

Put this program in a folder with blktiger.zip (MAME's Black Tiger ROM set,
the parent set) and run it: it writes BlackTiger.adf (60 Hz, as the arcade)
next to the ROM set. With --pal it writes BlackTiger-PAL.adf (50 Hz) as well.

usage: make_disk [path/to/blktiger.zip] [--pal]

Nothing of the game is in this program: every byte of the disk's game -
its code, graphics and sound - is made from your ROM set while it runs.
"""
import os
import runpy
import shutil
import sys
import time


def child_script():
    """The one-file builder runs the build's other scripts as processes of
    its own: make_disk --script path args..."""
    path = sys.argv[2]
    sys.argv = sys.argv[2:]
    sys.path.insert(0, os.path.dirname(path))
    runpy.run_path(path, run_name="__main__")


def here():
    if getattr(sys, "frozen", False):
        return os.path.dirname(os.path.abspath(sys.executable))
    return os.getcwd()


def find_roms(args):
    for a in args:
        if not a.startswith("-"):
            return os.path.abspath(a)
    for d in (here(), os.getcwd()):
        for name in ("blktiger.zip", "BLKTIGER.ZIP", "blktiger"):
            p = os.path.join(d, name)
            if os.path.exists(p):
                return p
    return None


def pause():
    """(a window opened by double-clicking closes when the program ends)"""
    if getattr(sys, "frozen", False) and os.name == "nt":
        try:
            input("\nPress Enter to close.")
        except EOFError:
            pass


def main():
    if len(sys.argv) > 2 and sys.argv[1] == "--script":
        child_script()
        return
    args = sys.argv[1:]
    print("Black Tiger for the Amiga 1200 - disk builder\n")
    roms = find_roms(args)
    if not roms:
        print("blktiger.zip was not found. Put MAME's Black Tiger ROM set (blktiger.zip) in the")
        print("same folder as this program, or give its path:  make_disk path/to/blktiger.zip")
        pause()
        sys.exit(1)
    root = getattr(sys, "_MEIPASS", None) or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    sys.path.insert(0, os.path.join(root, "tools"))
    import bt_rom
    try:
        bt_rom.load_roms(roms)
    except (Exception, SystemExit) as e:    # (a wrong or incomplete set: say which)
        print("%s isn't the Black Tiger ROM set this needs: %s" % (roms, e))
        print("It must be MAME's parent set 'blktiger' (see the tester guide).")
        pause()
        sys.exit(1)
    print("ROM set: %s (checked)\nBuilding - this takes a few minutes...\n" % roms)
    os.chdir(root)
    import build_game
    t = time.time()
    outs = []
    for pal in ([False, True] if "--pal" in args else [False]):
        sys.argv = ["build_game", "--roms", roms] + (["--pal"] if pal else [])
        build_game.main()
        dest = os.path.join(os.path.dirname(roms), "BlackTiger-PAL.adf" if pal else "BlackTiger.adf")
        shutil.copyfile(os.path.join(root, "build", "blacktiger.adf"), dest)
        outs.append(dest)
    print("\nDone in %d s:" % (time.time() - t))
    for o in outs:
        print("  " + o)
    print("\nThis disk is made from your ROM set: please don't share it.")
    pause()


if __name__ == "__main__":
    main()
