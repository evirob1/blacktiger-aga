#!/bin/bash
# Run the Amiga game build on Musashi (tools/harness/amiga_sim.c).
# usage: tools/harness/amiga_sim.sh seconds [dump_text_at_second ...]
set -e
cd "$(dirname "$0")/../.."
M=build/musashi
[ -f $M/m68kops.c ] || tools/harness/build.sh >/dev/null
gcc -O2 -w -I$M '-DM68K_INSTRUCTION_HOOK=M68K_OPT_SPECIFY_HANDLER' \
    '-DM68K_INSTRUCTION_CALLBACK(pc)=harness_hook(pc)' -include tools/harness/hook.h \
    -o build/amiga_sim tools/harness/amiga_sim.c $M/m68kcpu.c $M/m68kops.c $M/m68kdasm.c \
    $M/softfloat/softfloat.c -lm
(cd build/game && vasmm68k_mot -quiet -Fbin -m68020 -I. -I../../src -L game.lst -o game.bin ../../src/amiga_main.s)
export BT_RT_HEADER=$(awk '$1=="rt_header"{sub("[AE]:","",$2); print $2; exit}' build/game/game.lst)
export BT_TXSPR=$(awk '$1=="txspr"{sub("[AE]:","",$2); print $2; exit}' build/game/game.lst)
export BT_CHARS=$(awk '$1=="chars"{sub("[AE]:","",$2); print $2; exit}' build/game/game.lst)
export BT_TXSHADOW=$(awk '$1=="txshadow"{sub("[AE]:","",$2); print $2; exit}' build/game/game.lst)
PV=$(awk '$1=="pvars"{sub("[AE]:","",$2); print $2; exit}' build/game/game.lst)
PK=$(awk '$1=="pv_keys"{sub("[AE]:","",$2); print $2; exit}' build/game/game.lst)
export BT_PVKEYS=$(printf "%x" $((0x$PV + 0x$PK)))
PD=$(awk '$1=="pv_drawn"{sub("[AE]:","",$2); print $2; exit}' build/game/game.lst)
export BT_DRAWN=$(printf "%x" $((0x$PV + 0x$PD)))
build/amiga_sim build/game/game.bin "$@"
