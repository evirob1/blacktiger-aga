; Black Tiger AGA - test build of the FM synthesiser (src/fm_synth.s): plays a
; log of YM2203 register writes (tools/sound/fm_check.py: MAME's) through it
; as src/sound.s would, chunk by chunk, every sample of the mix to SY_TEST
; (tools/harness/sound_sim.c: SND_PCM).

CUSTOM		equ	$dff000
DMACON		equ	$096
INTENA		equ	$09a
INTREQ		equ	$09c
AUD0LC		equ	$0a0
SY_TEST		equ	$f00010
DONE		equ	$f00008

	org	$10000			; (where sound_sim loads it)
start:	lea	sy_space,a0
	lea	sy_out,a1
	bsr	sy_init
	lea	fm_events,a3
	moveq	#0,d5			; this chunk's start (units << 8)
.chunk	move.l	d5,d4
	add.l	#SY_UNITSCHUNK,d4	; its end
.ev	move.l	(a3),d0			; (time << 8)
	bmi.s	.end
	cmp.l	d4,d0
	bhs.s	.out
	sub.l	d5,d0			; up to it
	move.l	#SY_UNITSCHUNK,d1
	bsr	sy_render
	move.l	4(a3),d0		; chip << 16 | register << 8 | value
	addq.l	#8,a3
	move.l	d0,d6
	swap	d6			; chip
	move.w	d0,d1
	lsr.w	#8,d1			; register
	moveq	#0,d7
	move.b	d0,d7			; value
	lea	ym_regs,a0
	move.w	d6,d2
	lsl.w	#8,d2
	move.b	d1,d2
	move.b	d7,(a0,d2.w)
	exg	d2,d6
	bsr	sy_reg
	exg	d2,d6
	cmp.b	#$28,d1
	bne.s	.ev
	bsr	sy_key
	bra.s	.ev
.out	bsr	sy_finish
	move.l	d4,d5
	bra.s	.chunk
.end	bsr	sy_finish
	move.l	d5,DONE
.h	bra.s	.h

	include	"fm_synth.s"
	include	"fm_events.s"		; (fm_events: tools/sound/fm_check.py)

	cnop	0,4
ym_regs:	ds.b	512
sy_out:		ds.b	SY_BUFSIZE
	cnop	0,4
sy_space:	ds.b	SY_SIZE
