#!/bin/bash
# Boot an ADF in FS-UAE (A1200, AROS ROM) under Xvfb and take screenshots.
# usage: run_uae.sh ADF SECONDS OUTPREFIX [screenshot times in seconds...]
ADF=$1; SECS=$2; OUT=$3; shift 3
export SDL_AUDIODRIVER=dummy HOME=${TMPDIR:-/tmp}/bt-uae-home
mkdir -p $HOME
Xvfb :77 -screen 0 1024x768x24 >/dev/null 2>&1 &
XV=$!
sleep 1
DISPLAY=:77 fs-uae --amiga_model=A1200 --floppy_drive_0="$ADF" --floppy_drive_speed=0 \
  --fullscreen=0 --window_width=1024 --window_height=768 --fsaa=0 --texture_filter=nearest --scanlines=0 --rtg_scanlines=0 --zoom=${ZOOM:-640x512} \
  --floppies_dir=/tmp --automatic_input_grab=0 --initial_input_grab=0 --sound_card=0 \
  --uae_floppy0sound=-1 >uae.log 2>&1 &
UP=$!
T=0
for t in "$@"; do sleep $((t-T)); T=$t; DISPLAY=:77 import -window root ${OUT}_$t.png; done
sleep $((SECS-T)); kill $UP; sleep 1; kill $XV
