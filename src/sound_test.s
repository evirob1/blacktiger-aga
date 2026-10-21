; Black Tiger AGA - test build of the translated sound program: replays
; command latch writes, resets and timer interrupts (tools/harness/sound_check.py:
; those of a MAME run, to compare the YM2203 writes with MAME's) or plays
; commands with the timers as modelled (tools/sound/bank.py: the instrument
; patches), logging every YM2203 write.
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

start:	lea	snd_mem+$8000(pc),a0
	lea	snd_a6(pc),a1
	move.l	a0,(a1)
	bsr	snd_init
	lea	snd_events(pc),a5
	move.l	(a5)+,d7		; 1: the timers as modelled (src/sound.s), not MAME's
	moveq	#0,d5			; (now)
.ev	move.l	(a5)+,d6		; next event: time, what
	bmi.s	.end
	tst.l	d7
	beq.s	.now
.run	cmp.l	d6,d5			; run the timers up to it, 8 units at a time
	bhs.s	.now
	moveq	#8,d0
	bsr	snd_timer
	addq.l	#8,d5
	move.l	d5,TIME
	bra.s	.run
.now	move.l	d6,TIME
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
