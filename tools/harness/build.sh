#!/bin/bash
# Build the translation test harness (needs gcc and git; fetches Musashi).
set -e
cd "$(dirname "$0")/../.."
M=build/musashi
if [ ! -f $M/m68kcpu.c ]; then
    git clone -q --depth 1 https://github.com/kstenerud/Musashi.git $M
fi
if [ ! -f $M/m68kops.c ]; then
    gcc -O2 -o $M/m68kmake $M/m68kmake.c
    (cd $M && ./m68kmake . m68k_in.c >/dev/null)
fi
# per-instruction hook: the harness decides when the Z80 interrupt happens
gcc -O2 -w -I$M '-DM68K_INSTRUCTION_HOOK=M68K_OPT_SPECIFY_HANDLER' \
    '-DM68K_INSTRUCTION_CALLBACK(pc)=harness_hook(pc)' -include tools/harness/hook.h -o build/harness tools/harness/harness.c $M/m68kcpu.c $M/m68kops.c \
    $M/m68kdasm.c $M/softfloat/softfloat.c -lm
echo "built build/harness"
