# Environment for build/amiga_sim from the listing (sourced by amiga_sim.sh;
# source it to run build/amiga_sim directly, e.g. several at once)
export BT_RT_HEADER=$(awk '$1=="rt_header"{sub("[AE]:","",$2); print $2; exit}' build/game/game.lst)
export BT_CHIPA=$(awk '$1=="chipa"{sub("[AE]:","",$2); print $2; exit}' build/game/game.lst)
export BT_CATXSPR=$(awk '$1=="CA_TXSPR"{sub("[AE]:","",$2); print $2; exit}' build/game/game.lst)
export BT_CHARS=$(awk '$1=="chars"{sub("[AE]:","",$2); print $2; exit}' build/game/game.lst)
export BT_TXSHADOW=$(awk '$1=="txshadow"{sub("[AE]:","",$2); print $2; exit}' build/game/game.lst)
PV=$(awk '$1=="pvars"{sub("[AE]:","",$2); print $2; exit}' build/game/game.lst)
PK=$(awk '$1=="pv_keys"{sub("[AE]:","",$2); print $2; exit}' build/game/game.lst)
export BT_PVKEYS=$(printf "%x" $((0x$PV + 0x$PK)))
PD=$(awk '$1=="pv_drawn"{sub("[AE]:","",$2); print $2; exit}' build/game/game.lst)
export BT_DRAWN=$(printf "%x" $((0x$PV + 0x$PD)))
PI=$(awk '$1=="pv_indisp"{sub("[AE]:","",$2); print $2; exit}' build/game/game.lst)
export BT_INDISP=$(printf "%x" $((0x$PV + 0x$PI)))
PO=$(awk '$1=="pv_overload"{sub("[AE]:","",$2); print $2; exit}' build/game/game.lst)
export BT_OVL=$(printf "%x" $((0x$PV + 0x$PO)))
sym() { awk -v n=$1 '$1==n{sub("[AE]:","",$2); print $2; exit}' build/game/game.lst; }
if [ -f build/game/sound.bin.at ]; then   # (written by tools/mkadf.py)
  read AT_STOCK AT_FAST < build/game/sound.bin.at
  export BT_SOUND=build/game/sound.bin,$AT_STOCK,$AT_FAST
fi
if [ -f build/game/fx_bank.bin.at ]; then
  read FX_AT < build/game/fx_bank.bin.at
  export BT_FX=build/game/fx_bank.bin,$FX_AT
fi
SN=$(sym draw_snapped); [ -n "$SN" ] && export BT_SNAPPED=$SN
PS=$(sym pv_sprsnap); [ -n "$PS" ] && export BT_SPRSNAP=$(printf "%x" $((0x$PV + 0x$PS)))
export BT_BGRAM=$(sym bgram) BT_GRPGEN=$(sym grpgen)
