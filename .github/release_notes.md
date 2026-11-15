A test release of Black Tiger (Capcom, 1987) for the Amiga 1200 (AGA).

**There is no disk image here:** you make it yourself from your own MAME ROM set
(`blktiger.zip`), with the disk builder for your computer:

* `make_disk-windows.exe` - Windows
* `make_disk-macos` - macOS
* `make_disk-linux` - Linux

Put the builder and `blktiger.zip` in the same folder and run it: after a minute
or two `BlackTiger.adf` appears next to them. The builder contains nothing of
the game; please don't share the disk you make.

It runs on a stock A1200 (music and effects), better with fast RAM, and on a 68040/68060 with fast RAM the arcade's sound chips are
synthesised in real time. Read [TESTING.md](https://github.com/evirob1/blacktiger-aga/blob/main/TESTING.md)
for the ROM set's files, the hardware, the controls and what to report.

**New in v0.3**

* Music on a stock A1200: the arcade's tunes as notes on the Amiga's four
  channels, made from your ROM set by the builder, with the effects taking a
  channel while they play. It needs nearly all the chip RAM (1970 KB free at
  boot); with less, effects only as before.
* Fast RAM: the sampled instruments fade as the arcade's chips do (notes no
  longer ring on - level 5's lead sounded like an accordion).
* The border is always black (it sometimes took a colour from the game).
* 130 KB less memory used everywhere (a more compact table of jump targets).

**New in v0.2**

* 68040 / 68060: switching to the sampled sound with F10 no longer turns the
  CPU's caches off (the game slowed down from then on).
* The display does less work each frame: a little smoother in busy scenes,
  most of all on a stock A1200.

Make a new disk with this version's builder: disks made with older ones don't change.
