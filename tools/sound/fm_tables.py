"""src/fm_tables.i for the FM synthesiser (src/fm_synth.s): ymfm's sine and
power tables (as tools/sound/fm_lite.c has them; ymfm by Aaron Giles, BSD
licence), each envelope rate's average attenuation step per envelope clock,
and the SSG's volume curve.

usage: python3 tools/sound/fm_tables.py [src/fm_tables.i]
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))


def c_table(src, name):
    body = re.search(name + r"\[[^]]*\] = \{(.*?)\};", src, re.S).group(1)
    return [int(x, 16) for x in re.findall(r"0x[0-9a-fA-F]+", body)]


def env_averages(inc_tab):
    """per rate: attenuation steps per envelope clock, on average (as ymfm
    steps them: rate >> 2 = how often, inc_tab = how much)"""
    out = []
    for r in range(64):
        shift, total = r >> 2, 0
        for cnt in range(1 << 14):
            c = cnt << shift
            if c & 0x7ff:
                continue
            bits = (c >> (11 if shift <= 11 else shift)) & 7
            total += (inc_tab[r] >> (4 * bits)) & 15
        out.append(total / (1 << 14))
    return out


def words(name, values, comment, size="w"):
    lines = ["; " + comment, name + ":"]
    for i in range(0, len(values), 16 if size == "w" else 8):
        lines.append("\tdc.%s\t" % size + ",".join(str(v) for v in values[i:i + (16 if size == "w" else 8)]))
    return "\n".join(lines) + "\n"


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "src", "fm_tables.i")
    src = open(os.path.join(HERE, "fm_lite.c")).read()
    sin_tab, pow_src, inc_tab = (c_table(src, n) for n in ("sin_tab", "pow_src", "inc_tab"))
    assert len(sin_tab) == 256 and len(pow_src) == 256 and len(inc_tab) == 64
    avg = env_averages(inc_tab)
    # ymfm's SSG levels (0 to 16382 at volume 15, where an FM channel swings
    # +-8191: the same, peak to peak), as half amplitudes in mix units (an FM
    # channel: +-2048) - the square wave swings +- it
    amp = [0, 32, 78, 141, 178, 222, 262, 306, 369, 441, 509, 585, 701, 836, 965, 1112,
           1334, 1595, 1853, 2146, 2576, 3081, 3576, 4135, 5000, 6006, 7023, 8155, 9963, 11976, 14132, 16382]
    ssg = [0] + [round(amp[2 * v + 1] * 2048 / 16382) for v in range(1, 16)]
    text = ("; the FM synthesiser's tables (tools/sound/fm_tables.py: from ymfm, BSD licence)\n" +
            words("sy_sintab", sin_tab, "a quarter sine as attenuation (4.8)") +
            words("sy_powtab", pow_src, "attenuation fraction -> volume mantissa (| $400)") +
            words("sy_envavg", [round(a * 65536) for a in avg], "per rate: attenuation per envelope clock << 16", "l") +
            words("sy_ssgvol", ssg, "SSG volume 0-15 -> half amplitude (mix units)"))
    open(out, "w").write(text)


if __name__ == "__main__":
    main()
