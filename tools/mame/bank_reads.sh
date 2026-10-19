#!/bin/bash
# Record which Z80 instructions read data from the banked ROM window
# (slow: runs MAME with a watchpoint). Updates data/bank_reads.txt.
set -e
cd "$(dirname "$0")/../.."
mkdir -p analysis
"${MAME:-mame}" blktiger -rompath roms -video none -sound none -nothrottle -skip_gameinfo \
    -debug -debugger none -autoboot_script tools/mame/bank_reads.lua || true
python3 tools/mame/bank_reads.py
