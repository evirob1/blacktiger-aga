"""Black Tiger ROM loading and graphics decoding.

Layouts follow MAME's capcom/blktiger.cpp (parent set "blktiger").
Nothing in this file contains game data: everything is read from the
user's own ROM set at build time.
"""
import os
import zipfile
import zlib

# name -> (crc32, region, offset)
ROMS = {
    "bdu-01a.5e": (0xA8F98F22, "maincpu", 0x00000),
    "bdu-02a.6e": (0x7BEF96E8, "maincpu", 0x10000),
    "bdu-03a.8e": (0x4089E157, "maincpu", 0x20000),
    "bd-04.9e":   (0xED6AF6EC, "maincpu", 0x30000),
    "bd-05.10e":  (0xAE59B72E, "maincpu", 0x40000),
    "bd-06.1l":   (0x2CF54274, "audiocpu", 0x0000),
    "bd.6k":      (0xAC7D14F1, "mcu", 0x0000),
    "bd-15.2n":   (0x70175D78, "chars", 0x00000),
    "bd-12.5b":   (0xC4524993, "tiles", 0x00000),
    "bd-11.4b":   (0x7932C86F, "tiles", 0x10000),
    "bd-14.9b":   (0xDC49593A, "tiles", 0x20000),
    "bd-13.8b":   (0x7ED7A122, "tiles", 0x30000),
    "bd-08.5a":   (0xE2F17438, "sprites", 0x00000),
    "bd-07.4a":   (0x5FCCBD27, "sprites", 0x10000),
    "bd-10.9a":   (0xFC33CCC6, "sprites", 0x20000),
    "bd-09.8a":   (0xF449DE01, "sprites", 0x30000),
}
REGION_SIZE = {"maincpu": 0x50000, "audiocpu": 0x8000, "mcu": 0x1000,
               "chars": 0x8000, "tiles": 0x40000, "sprites": 0x40000}


def _read_files(path):
    files = {}
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as z:
            for n in z.namelist():
                files[os.path.basename(n).lower()] = z.read(n)
    else:
        for n in os.listdir(path):
            with open(os.path.join(path, n), "rb") as f:
                files[n.lower()] = f.read()
    return files


def load_roms(path):
    """Load blktiger.zip (or an unzipped directory). Verifies every CRC."""
    files = _read_files(path)
    regions = {r: bytearray(s) for r, s in REGION_SIZE.items()}
    missing, bad = [], []
    by_crc = {zlib.crc32(d): d for d in files.values()}
    for name, (crc, region, off) in ROMS.items():
        data = files.get(name)
        if data is None or zlib.crc32(data) != crc:
            data = by_crc.get(crc, data)    # (renamed in some sets: by its CRC)
        if data is None:
            missing.append(name)
            continue
        if zlib.crc32(data) != crc:
            bad.append(name)
        regions[region][off:off + len(data)] = data
    if missing or bad:
        raise SystemExit("ROM set problem - missing: %s  bad CRC: %s" % (missing, bad))
    return regions


def _bit(data, bitoff):
    return (data[bitoff >> 3] >> (7 - (bitoff & 7))) & 1


def decode_chars(rom):
    """8x8 2bpp text characters -> list of 64-entry pen lists."""
    xs = [0, 1, 2, 3, 8, 9, 10, 11]
    out = []
    for c in range(len(rom) // 16):
        base = c * 128
        px = []
        for y in range(8):
            for x in range(8):
                o = base + y * 16 + xs[x]
                px.append(_bit(rom, o + 4) << 1 | _bit(rom, o))
        out.append(px)
    return out


def decode_16x16(rom):
    """16x16 4bpp tiles/sprites (same layout for both) -> 256-entry pen lists."""
    half = len(rom) * 8 // 2
    xs = [0, 1, 2, 3, 8, 9, 10, 11,
          256, 257, 258, 259, 264, 265, 266, 267]
    out = []
    for c in range(len(rom) // 128):
        base = c * 512
        px = []
        for y in range(16):
            for x in range(16):
                o = base + y * 16 + xs[x]
                px.append(_bit(rom, half + o + 4) << 3 | _bit(rom, half + o) << 2 |
                          _bit(rom, o + 4) << 1 | _bit(rom, o))
        out.append(px)
    return out


def decode_palette(lo, hi):
    """xBRG_444 palette RAM (two 1K halves) -> list of 1024 (r,g,b) 8-bit tuples."""
    pal = []
    for i in range(1024):
        w = hi[i] << 8 | lo[i]
        b, r, g = (w >> 8) & 15, (w >> 4) & 15, w & 15
        pal.append((r * 17, g * 17, b * 17))
    return pal


def bg_offset(col, row, layout8x4):
    """Map tile (col,row) -> tile index in the 16K scroll RAM (MAME scan functions)."""
    if layout8x4:   # 128 x 64 tiles
        return (col & 0x0f) + ((row & 0x0f) << 4) + ((col & 0x70) << 4) + ((row & 0x30) << 7)
    return (col & 0x0f) + ((row & 0x0f) << 4) + ((col & 0x30) << 4) + ((row & 0x70) << 6)  # 64 x 128
