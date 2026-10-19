# Black Tiger AGA

A port of Capcom's *Black Tiger* (1987 arcade) to the Amiga 1200, aimed at a
**stock A1200 (68020 @ 14 MHz, 2 MB chip RAM, no fast RAM)**.

This repository contains **no Capcom data**. Every graphic, map and palette is
converted at build time from your own MAME ROM set (`blktiger.zip`, the parent
set). Please don't distribute the built disk images.

## Status

| Part | State |
|---|---|
| ROM loading and CRC check, graphics decoding (tiles, sprites, text) | done |
| Level maps and palettes extracted straight from ROM (all 8 levels) | done |
| AGA scrolling engine: 8 bitplanes, 256 colours, 50 fps 2-way scrolling | done, pixel-exact against a reference render |
| Main game code (Z80 to 68020 translation) | next |
| Sprites (blitter objects), text layer, priorities | planned |
| Protection MCU replacement, sound, WHDLoad/HD install | planned |

See [docs/PLAN.md](docs/PLAN.md) for the analysis, the stock-A1200 budget and the roadmap.

![The viewer running all eight levels](docs/viewer_levels.png)

## Building (Windows, macOS or Linux)

You need:

* **Python 3**: the build uses only the standard library.
* **vasm** (`vasmm68k_mot`): either on your PATH or set `VASM` to its full path.
  Windows binaries: http://sun.hasenbraten.de/vasm/ (Motorola syntax, m68k).

Then:

```
copy your blktiger.zip into roms\
python tools/build.py            (all 8 levels)
python tools/build.py --level 3  (just one)
```

The disk images are written to `build/viewer_level1.adf` … `viewer_level8.adf`.

## Running in WinUAE

1. Quickstart: model **A1200**, configuration **"Basic non-expanded A1200"** (2 MB chip, no fast RAM: the target machine). A Kickstart 3.x ROM is best; WinUAE's built-in AROS ROM also boots it.
2. Put `build/viewer_levelN.adf` in DF0: and start.
3. Joystick in port 2 scrolls the map; hold fire to scroll faster. If you leave
   it alone for two seconds it pans around by itself.

## Layout

```
src/boot.s            bootblock: loads the program into chip RAM
src/viewer.s          AGA level viewer (display engine, milestone 1)
tools/bt_rom.py       ROM set loading and graphics decoding (from MAME's driver)
tools/bt_level.py     level maps, palette scripts, tile layouts
tools/convert_level.py  level -> Amiga palette / 8-bitplane tiles / map
tools/mkadf.py        bootable ADF writer
tools/build.py        one-command build
tools/preview.py      PNG sheets of the ROM graphics (needs Pillow)
tools/render_ref.py   reference render used by the screenshot tests (needs Pillow)
tools/mame/*.lua      MAME scripts used to measure the arcade game
tools/test/           FS-UAE screenshot test harness
```
