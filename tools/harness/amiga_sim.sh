#!/bin/bash
# Run the Amiga game build on Musashi (tools/harness/amiga_sim.c).
# usage: tools/harness/amiga_sim.sh seconds [dump_text_at_second ...]
# (BT_FASTMODE=1: the program in fast RAM, as with a fast RAM expansion;
#  render its dumps with BT_BASE=800000)
set -e
cd "$(dirname "$0")/../.."
M=build/musashi
[ -f $M/m68kops.c ] || tools/harness/build.sh >/dev/null
gcc -O2 -w -I$M '-DM68K_INSTRUCTION_HOOK=M68K_OPT_SPECIFY_HANDLER' \
    '-DM68K_INSTRUCTION_CALLBACK(pc)=harness_hook(pc)' -DM68K_SEPARATE_READS=M68K_OPT_ON -DM68K_EMULATE_PMMU=M68K_OPT_OFF -include tools/harness/hook.h \
    -o build/amiga_sim tools/harness/amiga_sim.c $M/m68kcpu.c $M/m68kops.c $M/m68kdasm.c \
    $M/softfloat/softfloat.c -lm
(cd build/game && vasmm68k_mot -quiet -Fbin -m68020 -I. -I../../src -L game.lst -o game.bin ../../src/amiga_main.s)
. "$(dirname "$0")/sim_env.sh"
build/amiga_sim build/game/game.bin "$@"
