# Compare an FS-UAE screenshot (run_uae.sh, nearest filtering, 3x) with tools/render_ref.py.
# usage: compare_view.py shot.png build/levelN X Y
import os, sys, subprocess
from PIL import Image
shot, d, X, Y = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
subprocess.run(["python3", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "render_ref.py"), d, X, Y, "ref_exact.png"], check=True)
a = Image.open(shot).convert("RGB").load(); b = Image.open("ref_exact.png").load()
bad = tot = 0
for y in range(0, 205):            # FS-UAE prints status text over the bottom lines
    for x in range(256):
        tot += 1
        if a[128 + 3 * x + 1, 47 + 3 * y + 1] != b[x, y]:
            bad += 1
print("%s: %d / %d pixels differ" % (shot, bad, tot))
