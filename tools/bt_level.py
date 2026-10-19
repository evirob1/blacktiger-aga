"""Level data extraction: maps, palettes and the tile sets each level needs."""
import bt_rom

MAP_BASE = 0x30000          # 8 x 16K maps in banked ROM (bd-04 / bd-05)
PAL_BANK = 0x28000          # ROM offset of bank 6, mapped at Z80 0x8000
PAL_SCRIPT_TABLE = 0x28136  # 8 little-endian pointers, one per level


def z80_to_rom(addr, bank_base=PAL_BANK):
    return bank_base + (addr - 0x8000)


def level_palette_ram(rom, level):
    """Run the level's palette copy script -> 2K palette RAM image (d800-dfff)."""
    ram = bytearray(0x800)
    p = z80_to_rom(rom[PAL_SCRIPT_TABLE + 2 * level] | rom[PAL_SCRIPT_TABLE + 2 * level + 1] << 8)
    while True:
        src = rom[p] | rom[p + 1] << 8
        if src == 0xFFFF:
            break
        dst = rom[p + 2] | rom[p + 3] << 8
        n = rom[p + 4] | rom[p + 5] << 8
        s = z80_to_rom(src)
        ram[dst - 0xD800:dst - 0xD800 + n] = rom[s:s + n]
        p += 6
    return ram


def level_palette(rom, level):
    ram = level_palette_ram(rom, level)
    return bt_rom.decode_palette(ram[:0x400], ram[0x400:])


def level_map(rom, level):
    return bytes(rom[MAP_BASE + level * 0x4000:MAP_BASE + (level + 1) * 0x4000])


def map_cells(bg, layout8x4):
    """Yield (col,row,code,color,flipx) for every cell of the map."""
    w, h = (128, 64) if layout8x4 else (64, 128)
    for row in range(h):
        for col in range(w):
            t = bt_rom.bg_offset(col, row, layout8x4)
            attr = bg[2 * t + 1]
            yield col, row, bg[2 * t] | (attr & 7) << 8, (attr & 0x78) >> 3, bool(attr & 0x80)


def guess_layout(bg, tiles):
    """Pick the layout whose tile edges join up best (lower seam error)."""
    best = None
    for lay in (0, 1):
        w, h = (128, 64) if lay else (64, 128)
        grid = {}
        for col, row, code, color, flip in map_cells(bg, lay):
            grid[col, row] = (code, flip)
        err = 0
        for (col, row), (code, flip) in grid.items():
            if col + 1 < w:
                c2, f2 = grid[col + 1, row]
                a, b = tiles[code], tiles[c2]
                for y in range(0, 16, 4):
                    pa = a[y * 16 + (0 if flip else 15)]
                    pb = b[y * 16 + (15 if f2 else 0)]
                    err += pa != pb
        if best is None or err < best[0]:
            best = (err, lay)
    return best[1]
