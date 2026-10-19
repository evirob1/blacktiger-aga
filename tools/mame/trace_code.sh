#!/bin/bash
# Record which Z80 code the game runs (slow: MAME traces at ~15% speed).
# Merges the result into data/code_entries.txt.
set -e
cd "$(dirname "$0")/../.."
mkdir -p analysis
rm -f analysis/trace_fifo && mkfifo analysis/trace_fifo
LC_ALL=C awk '/^[0-9A-F][0-9A-F] [0-9A-F]{4}:/{k=$1" "substr($2,1,4); if(!(k in s)){s[k]=1; print "E", k}}' \
    analysis/trace_fifo > analysis/trace_new.txt &
"${MAME:-mame}" blktiger -rompath roms -video none -sound none -nothrottle -skip_gameinfo \
    -debug -debugger none -autoboot_script tools/mame/trace_code.lua || true
wait
sort -u data/code_entries.txt analysis/trace_new.txt -o data/code_entries.txt
rm -f analysis/trace_fifo
wc -l data/code_entries.txt
