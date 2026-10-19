# Black Tiger → A1200: analysis and plan

## 1. The arcade hardware (from MAME `capcom/blktiger.cpp` and the ROMs)

| | |
|---|---|
| Main CPU | Z80 @ 6 MHz, 32K fixed ROM + 16 × 16K banks at `$8000` |
| Sound | Z80 @ 3.58 MHz + 2 × YM2203 (FM + SSG), fed through a sound latch |
| Protection | i8751 MCU (`bd.6k`) on I/O port 7 |
| Screen | 256 × 224, ~59.6 Hz, interrupt twice per frame (lines 112 and 240) |
| Background | 16×16 tiles, 4bpp, 16 palettes, 2048 tiles; 16K map RAM viewed as 64×128 or 128×64 tiles |
| Sprites | 128 × 16×16, 4bpp, 8 palettes, pen 15 transparent |
| Text | 32×32 grid of 8×8 2bpp characters, 32 palettes, pen 3 transparent |
| Colours | 1024-entry palette, 12-bit RGB (`xBRG_444`) |
| Priority | background palettes 0–5 have "front" pens that are drawn **over** sprites |

The main program runs a small cooperative scheduler: 16 task slots at
`$E880` with per-task stacks; the interrupt decrements sleep counters and the
idle loop at `$00C3` spins until a task is ready.

## 2. What was measured (MAME, 5 minutes of attract-mode play)

| Measure | Result | Meaning for the A1200 |
|---|---|---|
| Main Z80 busy | median 22 %, p90 42 %, max 55 % | translated code should fit the 68020 |
| Sprites on screen | median 11, p90 25, max 42 | the blitter is the tight spot (see §4) |
| Sprite palettes per frame | ≤ 6 of 8 | |
| Colours on screen (one frame) | max ~100 | |

Static analysis of the ROMs (all 8 levels):

| Level | Distinct tiles (with palette/flip) | Background colours | Background + sprite colours |
|---|---|---|---|
| 1 | 485 | 120 | 170 |
| 2 | 477 | 108 | 160 |
| 3 | 651 | 108 | 157 |
| 4 | 737 | 96 | 145 |
| 5 | 549 | 110 | 163 |
| 6 | 488 | 114 | 167 |
| 7 | 439 | 105 | 165 |
| 8 | 366 | 113 | 161 |

So every level fits in AGA's 256 colours with an exact (not quantised)
palette: 128 entries for the background, 128 for sprites (8 × 16, identical
to the arcade layout) and the text layer on hardware-sprite colours.

### Where things are in the ROMs

* Level maps: 8 × 16K at ROM offset `$30000` (`bd-04`, `bd-05`), copied verbatim into map RAM.
* Level palettes: script table at `$28136` (bank 6) → per level a list of
  `(source, destination, length)` copies into palette RAM. `tools/bt_level.py` replays them.

## 3. Port architecture

**Game logic.** The main Z80 program is translated to 68020 assembly ahead
of time, not emulated. A translator maps Z80 registers to 68k data registers,
gives each scheduler task its own 68k stack, and turns banked ROM, I/O ports
and video RAM writes into calls into the Amiga "hardware layer". The
translated code then runs as the original did, including the original game
logic and timing.

**Background.** Done in milestone 1 (`src/viewer.s`):
* 8 bitplanes, FMODE=3, 256-pixel-wide window, 64-pixel AGA fine scroll.
* The buffer holds the full map width × 256 lines; vertically it wraps by
  changing the bitplane modulo on one copper line (so 8 separate planes,
  32K each).
* Only new tile rows are drawn (blitter), so scrolling costs almost nothing.
* Tiles are pre-converted per level to 8bpp with an exact palette.

**Sprites.** Blitter objects (bobs) using sprite colour banks at palette
entries 128–255, so a sprite needs only its 4 planes plus constant upper
planes. Background "front" pens are restored over the bobs from a
per-tile mask.

**Text layer.** AGA hardware sprites (4 × 64 pixels covers the 256-pixel
width, re-used down the screen). That costs no blitter time and keeps the
arcade's look.

**MCU.** Find what the main CPU asks for on port 7 (it's in `bd.6k`) and
answer it in 68k code.

**Sound.** To decide once the game runs. In order of preference:
1. Translate the sound Z80 program as well and drive Paula: SSG square
   channels map directly, and FM instruments become short samples.
2. Pre-render each tune and sound effect to samples (simplest, but memory-
   hungry on a 2 MB machine; needs streaming from disk or HD).

**Speed.** The arcade runs at 59.6 Hz. On PAL the game will run 1:1 with the
50 Hz frame (about 16 % slower) unless the 60 Hz NTSC display is chosen.
Both will be options.

## 4. Stock A1200 budget

One PAL frame = 20 ms ≈ 283,000 CPU cycles; bitplane DMA at FMODE=3 leaves
most chip bus slots free.

* **Game logic.** Peak 55 % of 6 MHz ≈ 55k Z80 T-states per arcade frame.
  At roughly 15 68020 cycles per Z80 instruction (code in chip RAM), that is
  about 110k cycles: ~40 % of a frame at peak, ~15 % typical. OK.
* **Sprites.** A 16×16 bob in 8 planes with background restore costs about
  0.6 ms of blitter time. 25 sprites (p90) ≈ 15 ms; the worst case of 42 ≈
  25 ms, more than one frame. Ways to reduce it, in order:
  * draw only the 4 sprite planes with the blitter and fill the bank bits
    with cheaper 2-channel blits;
  * restore only dirty 16×16 cells, not whole rectangles;
  * merge sprites the game builds from 2×2 blocks into one bob;
  * hardware sprites for the player or bullets.
* **Fallback.** Render at 25 fps when the screen is busy while the logic stays at 50 Hz.
* **Memory.** Code (~100K) + one level's tiles (≤ 184K) + sprites
  (128K at 4bpp + masks) + screen (256K) + sprite buffers comes to about
  1 MB of 2 MB chip RAM.

**Verdict:** a stock A1200 looks feasible at full colour. The open question
is a solid 50 fps in the busiest scenes. Fast RAM would help the CPU side
(translated code running from fast RAM is roughly 2–3× quicker) but not the
blitter.

## 5. Roadmap

1. **Done.** ROM tools, level and palette extraction, AGA scrolling viewer,
   emulator test harness (pixel-exact against a reference).
2. **Code map.** Run MAME with tracing to separate code from data across all
   banks; document the scheduler, the jump tables and the I/O usage.
3. **Translator.** Z80 → 68020 source generator plus a small runtime
   (scheduler, banking, I/O). First goal: the attract mode running with
   background only.
4. **Sprites and text.** Bobs, front-pen priority, hardware-sprite text, HUD.
5. **Input and MCU.** Playable.
6. **Sound.**
7. **Packaging.** Bootable floppy(s) and a WHDLoad / hard disk version.

## 6. Testing

`tools/test/run_uae.sh` boots an ADF in FS-UAE (A1200, AROS ROM) under Xvfb
and takes screenshots. `tools/test/compare_view.py` checks a screenshot pixel
by pixel against `tools/render_ref.py`. Build with
`python tools/build.py --level N --test X Y` to freeze the view at (X, Y).
Viewer results: 0 differing pixels at every position tested, including
copper buffer wraps and levels 1 and 3, plus 4 frames taken while scrolling.
