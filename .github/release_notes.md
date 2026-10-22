A test release of Black Tiger (Capcom, 1987) for the Amiga 1200 (AGA).

**There is no disk image here:** you make it yourself from your own MAME ROM set
(`blktiger.zip`), with the disk builder for your computer:

* `make_disk-windows.exe` - Windows
* `make_disk-macos` - macOS
* `make_disk-linux` - Linux

Put the builder and `blktiger.zip` in the same folder and run it: after a minute
or two `BlackTiger.adf` appears next to them. The builder contains nothing of
the game; please don't share the disk you make.

It runs on a stock A1200 (sound effects only), better with fast RAM (music and
effects), and on a 68040/68060 with fast RAM the arcade's sound chips are
synthesised in real time. Read [TESTING.md](https://github.com/evirob1/blacktiger-aga/blob/main/TESTING.md)
for the ROM set's files, the hardware, the controls and what to report.
