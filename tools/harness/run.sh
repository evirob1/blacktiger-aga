#!/bin/bash
# Translate, assemble and run the harness against the MAME recording.
# usage: tools/harness/run.sh [max_frames]
set -e
cd "$(dirname "$0")/../.."
python3 tools/z80/translate.py roms/blktiger.zip data/code_entries.txt build/game.s analysis/translate_report.txt --cycles
(cd build && vasmm68k_mot -quiet -Fbin -m68020 -I../src -I. -o harness_game.bin ../src/harness_main.s)
tools/harness/build.sh >/dev/null
(cd build && vasmm68k_mot -quiet -Fbin -m68020 -I../src -I. -L harness.lst -o /dev/null ../src/harness_main.s)
build/harness build/harness_game.bin analysis/rec/io.txt analysis/rec/ram.bin "$@"
