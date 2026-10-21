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
| Main game code: Z80 → 68020 translator and runtime | working: 3,000 frames of attract mode and play match MAME byte for byte (see [docs/TRANSLATOR.md](docs/TRANSLATOR.md)) |
| Translated game on the A1200: background, sprites, text layer, palette, joystick, keyboard | working (`build/blacktiger.adf`): game logic at full speed; the display drops to 25 fps on busy screens |
| Game sprites (player, enemies, shots) | done: blitter objects, double buffered; matches a MAME-style reference render |
| Background priority (scenery in front of sprites) | next |
| Code coverage of later levels | in progress: code the recordings never reached stops with a red screen |
| Sound | the arcade's sound program translated (its YM2203 register writes match MAME exactly), played through a software mixer of sampled FM instruments and SSG tones, or (68040 / 68060) the chips synthesised in real time; effects as samples on a stock A1200 |
| WHDLoad/HD install | planned |

See [docs/PLAN.md](docs/PLAN.md) for the analysis, the stock-A1200 budget and the roadmap.

![The viewer running all eight levels](docs/viewer_levels.png)

## Building (Windows, macOS or Linux)

You need:

* **Python 3**: the build uses only the standard library, except for sound.
* For sound: **numpy** (`pip install numpy`), **gcc**, **g++** and **git**.
  The build runs the sound program on a 68k emulator (Musashi, fetched with git
  and compiled with gcc) for its instrument samples, and renders the sound
  effects with ymfm (fetched with git, compiled with g++). Without them you get
  a silent disk.
* **vasm** (`vasmm68k_mot`): either on your PATH or set `VASM` to its full path.
  Windows binaries: http://sun.hasenbraten.de/vasm/ (Motorola syntax, m68k).

Then:

```
copy your blktiger.zip into roms\
python tools/build.py            (all 8 levels)
python tools/build.py --level 3  (just one)
```

The disk images are written to `build/viewer_level1.adf` … `viewer_level8.adf`.

The translated game itself:

```
python tools/build_game.py       -> build/blacktiger.adf (60 Hz, like the arcade)
python tools/build_game.py --pal -> 50 Hz version
```

Memory: a stock A1200 (2 MB chip RAM) is enough: the game takes about 1.9 MB
with sound (1.8 MB without: if there isn't room for sound, the game runs
silent). With fast RAM (about 1.35 MB free, e.g. any 4 MB expansion) the
program, the arcade's memory and the sound data go there and only the graphics
and the sound output stay in chip RAM, which makes the busy scenes noticeably
smoother. The same disk does both, automatically.

Sound: with fast RAM, the arcade's sound program runs (about 500 times a
second) and its 12 voices are mixed in software - music and effects, about a
third of the CPU. **F9** switches the music on or off (off silences the tune
playing; on starts with the next tune the game plays). On a stock A1200 there
is neither the room nor the time for that: the game plays the sound effects
as samples straight on Paula's four channels instead (rendered at build time
by ymfm, MAME's YM2203 emulation; about 2% of the CPU), the credit jingle and
the story page's tune, and no other music (the story tune is left out if chip
RAM is short). The game
itself always runs at full speed: sound costs display frames.

On a 68040 or 68060 with fast RAM the two YM2203s are synthesised instead, in
real time (src/fm_synth.s: FM operators, envelopes and the SSG as the chips do
them, after ymfm; 13.9 kHz, 14-bit output): much closer to the arcade, at
about 3.5 million instructions a second. **F10** switches between that and the
sampled player (on any CPU with fast RAM: try it on a fast 68030 too).

The default disk switches the A1200 to NTSC timing (60 Hz, 262 lines), the
arcade's own frame rate: the game runs at the original speed. That needs a
display that accepts 60 Hz (any 15 kHz arcade monitor or most TVs; WinUAE
handles it). The `--pal` disk stays at 50 Hz, so the game runs at 5/6 speed.

Controls: joystick in port 2 (fire = attack, second button or Space = jump,
or cursor keys / Ctrl), keyboard **5** = coin, **1** = 1 player start,
**2** = 2 players. Not there yet: scenery drawn in front of sprites (sprites
currently always appear on top).

Level select (for testing): **F1**-**F8** before starting a game makes it
start at the beginning of that level (1-8), with the equipment you start the
game with.

Test mode: the **Help** key switches it on and off (nothing shows it: the
power LED would, but on an A1200 its switch also turns the audio filter off).
You then have the strongest weapon, hits do no damage, and lives and time
never go down - handy for exploring. (Falling into a pit still costs the life you're on, so you
restart at the last checkpoint, but the game doesn't end.)

If the screen turns red with "UNKNOWN Z80 CODE / BANK xx AT xxxx", the game
reached Z80 code the translator hasn't seen yet: please report those numbers
(and the "FROM xx xxxx" line under them, where the jump came from) and where
it happened.

## Running in WinUAE

1. Quickstart: model **A1200**, configuration **"Basic non-expanded A1200"** (2 MB chip, no fast RAM: the target machine). A Kickstart 3.x ROM is best; WinUAE's built-in AROS ROM also boots it.
2. Put `build/viewer_levelN.adf` in DF0: and start.
3. Joystick in port 2 scrolls the map; hold fire to scroll faster. If you leave
   it alone for two seconds it pans around by itself.

## Layout

```
src/boot.s            bootblock: loads the program and the sound data
src/sound.s           the arcade's sound CPU: its translated program's runtime, YM2203 registers
src/sound_play.s      the sound player: YM2203 registers -> sampled voices, mixed for Paula
src/fx_play.s         the sound effects as samples (no fast RAM)
src/fm_synth.s        the YM2203s synthesised (68040 / 68060 with fast RAM; src/fm_test.s: its test)
tools/sound/          YM2203 FM model, the instrument bank, the effects' samples (needs numpy)
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
tools/z80/            Z80 decoder, code map, timing table and the translator
src/rt_core.s         runtime for the translated game (scheduler, banks, I/O)
src/harness_main.s    test build of the translated game
src/amiga_main.s      the A1200 build: interrupts, inputs, display (background, sprites, text, palette)
tools/convert_game.py graphics for the A1200 build
tools/build_game.py   one-command build of build/blacktiger.adf
tools/harness/amiga_sim.*     runs the A1200 build on Musashi (speed, memory dumps)
tools/harness/render_frame.py draws a frame from such a dump, following the copper list
tools/harness/render_arcade.py draws the same frame the way MAME does, and compares
tools/harness/uss.py          unpacks a WinUAE save state for amiga_sim to carry on from
                              (BT_RESUME, BT_BASE; BT_RANDJOY=seed plays at random;
                              BT_POKEAT=offset:addr:value e.g. starts a game on level N)
tools/lzpack.py       packer for the disk data (unpacked at boot)
tools/harness/        68k test harness (Musashi) that checks the translation against MAME
data/code_entries.txt Z80 code addresses seen running in MAME (addresses only)
```
