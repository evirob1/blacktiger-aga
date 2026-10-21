; Black Tiger AGA - test build of the translated sound program
; (tools/harness/sound_check.py): replays the command latch writes, resets
; and timer interrupts of a MAME run and logs every YM2203 write, to compare
; with MAME's.
;
; Logging: a long to LOG ($F00000) = chip << 16 | register << 8 | value;
; TIME ($F00004) = the time now; DONE ($F00008) ends the run.

LOG	equ	$f00000
TIME	equ	$f00004
DONE	equ	$f00008

	include	"rt_defs.s"

SNDLOG	macro
	move.l	d6,-(sp)
	swap	d6			; chip << 16
	move.b	d0,d6
	lsl.w	#8,d6
	move.b	d7,d6
	move.l	d6,LOG
	move.l	(sp)+,d6
	endm

start:	bsr	snd_init
	lea	snd_events(pc),a5
.ev	move.l	(a5)+,d6		; next event: time, what
	bmi.s	.end
	move.l	d6,TIME
	move.l	(a5)+,d0		; $00-$FF: the latch, $100 / $101: reset
	btst	#9,d0			; off / on, $200 / $201: timer A / B flag
	bne.s	.t
	btst	#8,d0
	bne.s	.r
	lea	snd_latch(pc),a0
	move.b	d0,(a0)
	bra.s	.ev
.r	lsl.b	#5,d0
	bsr	snd_reset
	bra.s	.ev
.t	lea	snd_tvars(pc),a0
	and.w	#1,d0
	bset	d0,ST_STATUS(a0)
	moveq	#0,d0			; (no time passes: the interrupt runs now)
	bsr	snd_timer
	bra.s	.ev
.end	move.l	d6,DONE
.h	bra.s	.h

z80_bad_jump:
	move.l	d7,DONE
	illegal

	include	"sound.s"

snd_rom:	incbin	"snd_rom.bin"
	include	"sound_events.s"	; (snd_events: from the MAME log)

	cnop	0,4
snd_rt:		ds.b	RT_SIZE
ym_regs:	ds.b	512
ym_keyon:	ds.b	6
	cnop	0,4
snd_mem:	ds.b	65536
