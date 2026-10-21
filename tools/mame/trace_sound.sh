#!/bin/bash
# Record which code the sound CPU runs, playing every sound command.
# Writes data/sound_entries.txt (addresses only).
set -e
cd "$(dirname "$0")/../.."
mkdir -p analysis
rm -f analysis/trace_fifo && mkfifo analysis/trace_fifo
LC_ALL=C awk '/^[0-9A-F]{4}:/{k=substr($1,1,4); if(!(k in s)){s[k]=1; print "E 00", k}}' \
    analysis/trace_fifo > analysis/trace_sound.txt &
"${MAME:-mame}" blktiger -rompath roms -video none -sound none -nothrottle -skip_gameinfo \
    -debug -debugger none -autoboot_script tools/mame/trace_sound.lua || true
wait
sort -u analysis/trace_sound.txt -o data/sound_entries.txt
rm -f analysis/trace_fifo
wc -l data/sound_entries.txt
