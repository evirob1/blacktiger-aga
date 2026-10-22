# Black Tiger for the Amiga 1200 – tester guide

Thanks for trying it! This is a conversion of Capcom's 1987 arcade game
*Black Tiger* to the Amiga 1200 (AGA). The arcade's own program runs,
translated from the Z80 to the 68020. The graphics, sound and game logic
all come from the arcade ROMs.

## Making the disk

**There is no disk image to download.** The game's code, graphics and sound
belong to Capcom. You make the disk yourself from your own copy of the arcade
ROM set, with a small builder program that contains none of the game.
**Please don't share the disk image you make.**

1. **The ROM set.** You need MAME's `blktiger.zip` (the parent set, *Black
   Tiger*, not the bootleg or *Black Dragon*). It must contain these 16 files.
   They are checked by CRC, so a set with renamed files works too:

   | file | CRC32 | | file | CRC32 |
   |---|---|---|---|---|
   | bdu-01a.5e | a8f98f22 | | bd-12.5b | c4524993 |
   | bdu-02a.6e | 7bef96e8 | | bd-11.4b | 7932c86f |
   | bdu-03a.8e | 4089e157 | | bd-14.9b | dc49593a |
   | bd-04.9e | ed6af6ec | | bd-13.8b | 7ed7a122 |
   | bd-05.10e | ae59b72e | | bd-08.5a | e2f17438 |
   | bd-06.1l | 2cf54274 | | bd-07.4a | 5fccbd27 |
   | bd.6k | ac7d14f1 | | bd-10.9a | fc33ccc6 |
   | bd-15.2n | 70175d78 | | bd-09.8a | f449de01 |

2. **The builder.** Download `make_disk` for your computer from the project's
   Releases page: `make_disk-windows.exe`, `make_disk-macos` or
   `make_disk-linux`.

3. **Build.** Put the builder and `blktiger.zip` in the same folder and run
   the builder:
   * **Windows:** double-click it. SmartScreen may warn about an unknown
     program; choose *More info → Run anyway*.
   * **macOS:** in Terminal, `chmod +x make_disk-macos` and then
     `./make_disk-macos`. The first time, macOS may block it: allow it under
     *System Settings → Privacy & Security*, or right-click it and choose *Open*.
   * **Linux:** `chmod +x make_disk-linux && ./make_disk-linux`

   It takes a minute or two and writes **`BlackTiger.adf`** next to the ROM
   set. That disk runs at 60 Hz, like the arcade. Run the builder with `--pal`
   to also get `BlackTiger-PAL.adf`, which runs at 50 Hz (5/6 speed) for
   displays that can't show 60 Hz.

## Hardware

The same disk adapts to the machine it boots on:

| machine | what you get |
|---|---|
| A1200, 2 MB chip RAM, no fast RAM | Game at full speed. Sound effects as samples (plus the credit jingle and the story tune); no other music. Busy scenes drop display frames. |
| A1200 + fast RAM (any 4 MB or more) | Music and effects: the arcade's sound program runs, with its FM instruments played as samples. Smoother display. |
| 68040 / 68060 + fast RAM | As above, but the two YM2203 sound chips are synthesised in real time: much closer to the arcade. **F10** switches back to the sampled sound if it costs too many frames. |
| piStorm (Emu68), Vampire, other | Untested: please report! |

It boots from the floppy (DF0:) with any Kickstart 3.x. It also boots from a
Gotek or from an ADF in an emulator. Hard drive / WHDLoad installation isn't
there yet.

**60 Hz:** the default disk switches the A1200 to NTSC timing (60 Hz), the
arcade's own speed. Most TVs, 15 kHz monitors and WinUAE handle it. If your
display can't, use the PAL disk.

**WinUAE:** model A1200, Kickstart 3.x. For the fast-RAM version add Z3 or
Z2 fast RAM. For the 68040/68060 synth, set CPU speed to *Fastest possible*;
JIT is fine.

## Controls

* Joystick in port 2: **fire** = attack, **second button** (or **Space**,
  or **Left Alt**) = jump. The cursor keys and **Ctrl** work too.
* **5** = insert coin, **1** = one player start, **2** = two players.
* **F9**: music on/off (fast RAM). **F10**: synthesised / sampled sound
  (68040/060).
* **F1–F8** before starting a game: start at that level.
* **Help**: test mode on/off. You get the strongest weapon, no damage, and
  lives and time never run out. Holding jump while rising keeps you rising,
  to reach ledges you can't otherwise. Nothing on screen shows that it's on.

## What's as the arcade (not bugs)

* The *Black Tiger* logo loses its shading once a coin is in.
* After the ending and the staff credits the game restarts from its boot
  screen, without a high-score entry. The arcade does exactly this.
* The story page's lightning flashes the whole palette.

## What to report

Please open an issue on the project's GitHub page (or reply in the thread
where you found this) with:

1. **Your machine:** A1200 revision if you know it, accelerator and CPU,
   chip and fast RAM, Kickstart version, how you booted it (floppy, Gotek,
   emulator and its settings), and your display (60 Hz OK?).
2. **What happened:** where in the game (level, what you did just before),
   what you saw or heard, and whether it happens again.
3. **A screenshot or video** helps. On WinUAE, a **save state** (`.uss`) taken
   just before the problem is the most useful thing of all.
4. **Impressions:** is the frame rate OK on your machine? How does the sound
   compare with the arcade?

A red screen with "UNKNOWN Z80 CODE" means the game reached code the
conversion has never seen. Please photograph it: the numbers on it say where.
