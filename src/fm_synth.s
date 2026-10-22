; Black Tiger AGA - the two YM2203s synthesised (a 68040 / 68060 with fast
; RAM): FM as the chip does it (after ymfm, MAME's emulation by Aaron Giles,
; BSD licence: its sine and power tables, algorithms, envelope rates and phase
; steps; tools/sound/fm_lite.c is the model in C), at Paula's rate instead of
; the chip's - one operator evaluation a sample, the phases stepped by the
; chip's time - and the SSG's tones and noise; mixed to 16 bits, played as
; 14 (a channel at volume 64 for the high byte, one at 1 for the low 6 bits,
; on both sides).
;
;   sy_init     a0 = the synth's memory (SY_SIZE, fast RAM), a1 = the output
;               buffers (chip RAM, SY_BUFSIZE): tables, then audio running
;   sy_render   (snd_timer's hook) d0 = time of this call so far, d1 = all of
;               it (timer units): renders the chunk up to there
;
; Envelopes are stepped once a segment (between the sound program's timer
; interrupts, when registers change) by their average rates; register writes
; take effect at the start of the next segment, key on / off events in order
; (sy_key, from src/sound.s's ym_write).

SY_PERIOD	equ	256			; 13855 Hz
SY_CHUNK	equ	144			; samples per chunk: 10.4 ms
SY_BUFSIZE	equ	4*2*SY_CHUNK
; YM timer units (72 YM clocks) per chunk, << 8 (as src/sound_play.s's UNITS_CHUNK)
SY_UNITSCHUNK	equ	132279		; (SY_CHUNK * SY_PERIOD = CHUNK * PERIOD there)
; phase steps: the chip's (10.10, per FM sample at clock / 72) scaled to ours,
; for a phase with the 10-bit sine index in bits 16-25 (<< 22, then >> 6)
SY_STEPK	equ	14698			; 4096 * (3579545 / 72) / 13855
; envelope clocks (every third FM sample) per output sample, << 16
SY_ECLK		equ	78374			; 65536 * 49716 / 13855 / 3
; SSG steps (a cycle = 1 << 32): (clock / 32 / period) / 13855, << 28
SY_SSGK		equ	2167400000		; (3579545 / 32) / 13855 * (1 << 28)
SY_GAIN		equ	9744			; the mix -> 16 bits (<< 12): MAME's level, -3 dB
SY_SUB		equ	72			; samples at most between envelope steps
SY_ENVMIN	equ	24			; envelope clocks at least a step (20 samples)

	rsreset				; an operator
OP_PHASE	rs.l	1
OP_STEP		rs.l	1
OP_ATT		rs.l	1		; attenuation (10 bits) << 16 | fraction
OP_LVL		rs.w	1		; (att + total level) << 2, for the segment
OP_SL		rs.w	1		; sustain level (10 bits)
OP_RATE		rs.b	4		; attack, decay, sustain, release (0-63)
OP_STATE	rs.b	1
OP_KEY		rs.b	1
OP_TL		rs.w	1		; total level << 3
OP_SIZE		rs.b	0

	rsreset				; an FM channel
CH_OP		rs.b	4*OP_SIZE	; slots 1-4
CH_FB1		rs.w	1		; operator 1's last two outputs
CH_FB2		rs.w	1
CH_FBSH		rs.w	1		; feedback: shift (10 - FB)
CH_FBMASK	rs.w	1		; ... $FFFF, or 0 for none
CH_ALG		rs.w	1
CH_LIVE		rs.w	1		; any operator to be heard
CH_SIZE		rs.b	0

	rsreset				; an SSG channel
SG_PHASE	rs.l	1
SG_STEP		rs.l	1
SG_VOL		rs.w	1		; half its amplitude (0: off)
SG_MODE		rs.w	1		; bit 0: tone on, bit 1: noise on
SG_SIZE		rs.b	0

ST_ATTACK	equ	0
ST_DECAY	equ	1
ST_SUSTAIN	equ	2
ST_RELEASE	equ	3

	rsreset				; the synth's memory
SY_SIN		rs.w	1024		; abs(sin) attenuation, - 8192 in the negative half
SY_EXPN		rs.w	8192		; attenuation - 8192 -> -volume
SY_EXP		rs.w	8192		; attenuation -> volume
SY_CH		rs.b	6*CH_SIZE
SY_SG		rs.b	6*SG_SIZE
SY_MIX		rs.w	SY_CHUNK	; the chunk being made
SY_NBUF		rs.b	SY_CHUNK	; sy_ssg: a chip's noise for the segment
SY_NOISE	rs.l	2		; per chip: LFSR
SY_NPHASE	rs.l	2		; per chip: noise clock phase
SY_NSTEP	rs.l	2
SY_ENVF		rs.l	1		; envelope clocks not yet run << 16
SY_POS		rs.w	1		; samples of the chunk made
SY_HALF		rs.w	1		; the half being filled next
SY_BUF		rs.l	1		; output buffers (chip RAM)
SY_UNITS	rs.l	1		; YM timer time not yet run (<< 8)
SY_KEYQ		rs.w	32		; key on / off events: chip << 8 | slots << 4 | channel
SY_KEYN		rs.w	1		; events queued
SY_DIRTY	rs.b	8		; per chip: channels 0-2 and the SSG (3) written to
SY_SIZE		rs.b	0

sy_init:
	movem.l	d0-d7/a0-a6,-(sp)
	move.l	a0,a5
	lea	sy_mem(pc),a2
	move.l	a0,(a2)
	move.l	a1,SY_BUF(a5)
	move.w	#1,SY_HALF(a5)		; (half 0 plays first)
	clr.w	SY_POS(a5)
	clr.w	SY_KEYN(a5)
	clr.l	SY_UNITS(a5)
	clr.l	SY_ENVF(a5)
	moveq	#-1,d0
	move.l	d0,SY_DIRTY(a5)
	move.l	d0,SY_DIRTY+4(a5)
	lea	SY_CH(a5),a0		; channels, SSG, the mix cleared
	move.w	#(6*CH_SIZE+6*SG_SIZE+2*SY_CHUNK)/2-1,d0
.cl	clr.w	(a0)+
	dbf	d0,.cl
	lea	SY_CH(a5),a0		; operators silent
	moveq	#6-1,d1
.chn	moveq	#4-1,d0
.op	move.l	#$3ff<<16,OP_ATT(a0)
	move.w	#$3ff<<2,OP_LVL(a0)
	move.b	#ST_RELEASE,OP_STATE(a0)
	lea	OP_SIZE(a0),a0
	dbf	d0,.op
	lea	CH_SIZE-4*OP_SIZE(a0),a0
	dbf	d1,.chn
	moveq	#1,d0
	move.l	d0,SY_NOISE(a5)
	move.l	d0,SY_NOISE+4(a5)
	lea	SY_SIN(a5),a0		; the sine: 1024 entries from the quarter
	lea	sy_sintab(pc),a1
	moveq	#0,d0
.sn	move.w	d0,d1
	btst	#8,d1
	beq.s	.s1
	not.w	d1
.s1	and.w	#$ff,d1
	move.w	(a1,d1.w*2),d2
	btst	#9,d0
	beq.s	.s2
	sub.w	#8192,d2
.s2	move.w	d2,(a0)+
	addq.w	#1,d0
	cmp.w	#1024,d0
	bne.s	.sn
	lea	SY_EXP(a5),a0		; attenuation (4.8) -> 13-bit volume
	lea	sy_powtab(pc),a1
	moveq	#0,d0
.ex	move.w	d0,d1
	and.w	#$ff,d1
	moveq	#0,d2
	move.w	(a1,d1.w*2),d2
	or.w	#$400,d2
	lsl.l	#2,d2
	move.w	d0,d1
	lsr.w	#8,d1
	lsr.l	d1,d2
	move.w	d2,(a0)
	neg.w	d2
	move.w	d2,-8192*2(a0)
	addq.l	#2,a0
	addq.w	#1,d0
	cmp.w	#8192,d0
	bne.s	.ex
	move.l	SY_BUF(a5),a0		; the output silent
	move.w	#SY_BUFSIZE/4-1,d0
.cb	clr.l	(a0)+
	dbf	d0,.cb
	lea	CUSTOM,a6		; Paula: 14 bits on both sides
	move.w	#$000f,DMACON(a6)
	move.l	SY_BUF(a5),a0
	lea	AUD0LC(a6),a1
	moveq	#4-1,d0
.ch	move.l	a0,(a1)
	move.w	#SY_CHUNK/2,4(a1)
	move.w	#SY_PERIOD,6(a1)
	lea	16(a1),a1
	lea	2*SY_CHUNK(a0),a0
	dbf	d0,.ch
	move.w	#64,AUD0LC+8(a6)	; 0, 1: the high bytes
	move.w	#64,AUD0LC+$18(a6)
	move.w	#1,AUD0LC+$28(a6)	; 2, 3: the low 6 bits
	move.w	#1,AUD0LC+$38(a6)
	ifnd	SY_TEST
	movec	vbr,a0
	lea	sy_irq(pc),a1
	move.l	a1,$70(a0)
	move.w	#$0780,INTREQ(a6)
	move.w	#$c080,INTENA(a6)	; channel 0's block interrupt
	move.w	#$800f,DMACON(a6)
	endif
	movem.l	(sp)+,d0-d7/a0-a6
	rts

	ifnd	SY_TEST
; channel 0 starts a block (a chunk): point every channel at the other half,
; run the sound program for a chunk's time (snd_timer: it renders as it goes,
; sy_render), finish the chunk there
sy_irq:
	movem.l	d0-d7/a0-a6,-(sp)
	lea	CUSTOM,a6
	move.w	#$0080,INTREQ(a6)
	move.w	#$0080,INTREQ(a6)
	move.l	sy_mem(pc),a5
	move.w	SY_HALF(a5),d0
	mulu.w	#SY_CHUNK,d0
	move.l	SY_BUF(a5),a0
	add.l	d0,a0
	lea	AUD0LC(a6),a1
	moveq	#4-1,d1
.lc	move.l	a0,(a1)
	lea	16(a1),a1
	lea	2*SY_CHUNK(a0),a0
	dbf	d1,.lc
	move.l	SY_UNITS(a5),d0		; the sound program, for a chunk's time
	add.l	#SY_UNITSCHUNK,d0
	move.l	d0,d1
	and.l	#$ff,d1
	move.l	d1,SY_UNITS(a5)
	lsr.l	#8,d0
	bsr	snd_timer
	bsr	sy_finish
	movem.l	(sp)+,d0-d7/a0-a6
	rte
	endif

; the rest of the chunk made, out to the half being filled
sy_finish:
	moveq	#1,d0
	moveq	#1,d1
	bsr	sy_render
	bra	sy_output

; snd_timer's hook: d0 = units run so far in this call, d1 = all of them ->
; the chunk made up to the same point
sy_render:
	movem.l	d0-d7/a0-a6,-(sp)
	move.l	sy_mem(pc),a5
	tst.l	d1
	beq.s	.x
	mulu.l	#SY_CHUNK,d0
	divu.l	d1,d0			; target sample
	cmp.l	#SY_CHUNK,d0
	bls.s	.t
	move.l	#SY_CHUNK,d0
.t	move.w	d0,d7
	sub.w	SY_POS(a5),d7		; samples to make
	ble.s	.x
	move.w	d0,-(sp)
	bsr	sy_keys			; register writes since: their effect
	bsr	sy_params
	move.w	SY_POS(a5),d0
	lea	SY_MIX(a5,d0.w*2),a4
	move.w	(sp),d7
	sub.w	d0,d7
.sub	moveq	#SY_SUB,d0		; in steps of SY_SUB samples at most,
	cmp.w	d0,d7			; the envelopes stepped before each
	bhs.s	.n
	move.w	d7,d0
.n	sub.w	d0,d7
	movem.l	d0/d7/a4,-(sp)
	bsr	sy_envelopes
	movem.l	(sp),d0/d7/a4
	bsr	sy_segment
	movem.l	(sp)+,d0/d7/a4
	lea	(a4,d0.w*2),a4
	tst.w	d7
	bne.s	.sub
	move.w	(sp)+,SY_POS(a5)
.x	movem.l	(sp)+,d0-d7/a0-a6
	rts

; the chunk made: into the half being filled (14 bits: high bytes on 0 / 1,
; low 6 bits on 2 / 3), then a new one
sy_output:
	movem.l	d0-d7/a0-a6,-(sp)
	move.l	sy_mem(pc),a5
	move.w	SY_HALF(a5),d0
	mulu.w	#SY_CHUNK,d0
	move.l	SY_BUF(a5),a0
	add.l	d0,a0			; channel 0's half
	lea	2*SY_CHUNK(a0),a1	; 1
	lea	2*SY_CHUNK(a1),a2	; 2
	lea	2*SY_CHUNK(a2),a3	; 3
	lea	SY_MIX(a5),a4
	move.l	#32767,d2
	move.l	#-32768,d3
	move.w	#SY_CHUNK-1,d7
.s	move.w	(a4),d0
	clr.w	(a4)+
	muls.w	#SY_GAIN,d0
	asr.l	#8,d0
	asr.l	#4,d0
	cmp.l	d2,d0
	ble.s	.c1
	move.l	d2,d0
.c1	cmp.l	d3,d0
	bge.s	.c2
	move.l	d3,d0
.c2
	ifd	SY_TEST
	move.w	d0,SY_TEST
	endif
	move.w	d0,d1
	asr.w	#8,d0
	move.b	d0,(a0)+
	move.b	d0,(a1)+
	lsr.w	#2,d1
	and.b	#63,d1
	move.b	d1,(a2)+
	move.b	d1,(a3)+
	dbf	d7,.s
	clr.w	SY_POS(a5)
	eori.w	#1,SY_HALF(a5)
	movem.l	(sp)+,d0-d7/a0-a6
	rts

; a register written (from ym_write: d6.w = chip << 8 | register): its
; channel's settings to be worked out again
sy_reg:
	movem.l	d0/a0,-(sp)
	move.l	sy_mem(pc),a0
	moveq	#3,d0			; the channel (3: the SSG)
	cmp.b	#$30,d6
	bhs.s	.fm
	cmp.b	#$10,d6
	bhs.s	.x
	bra.s	.d
.fm	and.w	d6,d0
.d	btst	#8,d6			; chip 1: 4 on
	beq.s	.c0
	addq.w	#4,d0
.c0	st	SY_DIRTY(a0,d0.w)
.x	movem.l	(sp)+,d0/a0
	rts

; a key on / off (from ym_write: d6 = chip, d7 = slots << 4 | channel)
sy_key:
	movem.l	d0/a0,-(sp)
	move.l	sy_mem(pc),a0
	move.w	SY_KEYN(a0),d0
	cmp.w	#32,d0
	bhs.s	.x
	addq.w	#1,SY_KEYN(a0)
	lea	SY_KEYQ(a0,d0.w*2),a0
	move.w	d6,d0
	lsl.w	#8,d0
	move.b	d7,d0
	move.w	d0,(a0)
.x	movem.l	(sp)+,d0/a0
	rts

; the queued key events, in order
sy_keys:
	move.w	SY_KEYN(a5),d6
	beq.s	.x
	clr.w	SY_KEYN(a5)
	lea	SY_KEYQ(a5),a3
	subq.w	#1,d6
.e	move.w	(a3)+,d0
	moveq	#3,d1
	and.w	d0,d1			; channel
	cmp.w	#3,d1
	beq.s	.ne
	move.w	d0,d2
	lsr.w	#8,d2			; chip
	mulu.w	#3,d2
	add.w	d1,d2
	mulu.w	#CH_SIZE,d2
	lea	SY_CH(a5,d2.l),a0
	lsr.b	#4,d0			; slots 1-4: bits 0-3
	moveq	#4-1,d3
.s	lsr.b	#1,d0
	scs	d1
	cmp.b	OP_KEY(a0),d1
	beq.s	.n
	move.b	d1,OP_KEY(a0)
	bne.s	.on
	move.b	#ST_RELEASE,OP_STATE(a0)
	bra.s	.n
.on	move.b	#ST_ATTACK,OP_STATE(a0)
	clr.l	OP_PHASE(a0)
	cmp.b	#62,OP_RATE(a0)		; (the rate as last worked out)
	blo.s	.n
	clr.l	OP_ATT(a0)
.n	lea	OP_SIZE(a0),a0
	dbf	d3,.s
.ne	dbf	d6,.e
.x	rts

; every channel's settings from the register image (ym_regs)
sy_params:
	lea	SY_CH(a5),a0
	lea	ym_regs(pc),a2
	moveq	#0,d6			; chip << 8 | channel
.ch	move.w	d6,d0			; (written to since?)
	lsr.w	#6,d0
	or.b	d6,d0
	tst.b	SY_DIRTY(a5,d0.w)
	beq	.nch
	clr.b	SY_DIRTY(a5,d0.w)
	moveq	#0,d0			; block / F-number
	move.b	$a4(a2,d6.w),d0
	and.w	#$3f,d0
	lsl.w	#8,d0
	move.b	$a0(a2,d6.w),d0
	move.w	d0,d1			; keycode: block << 2 | F11 F10 ...
	lsr.w	#8,d1
	lsr.w	#2,d1
	and.w	#15,d1
	add.w	d1,d1
	move.w	d0,d2
	lsr.w	#7,d2
	and.w	#15,d2
	move.w	#$fe80,d3
	btst	d2,d3
	beq.s	.k0
	addq.w	#1,d1
.k0	move.b	$b0(a2,d6.w),d2		; FB / ALG
	moveq	#7,d3
	and.w	d2,d3
	move.w	d3,CH_ALG(a0)
	lsr.b	#3,d2
	and.w	#7,d2
	sne	d3
	ext.w	d3
	move.w	d3,CH_FBMASK(a0)
	moveq	#10,d3
	sub.w	d2,d3
	move.w	d3,CH_FBSH(a0)
	lea	sy_slots(pc),a1		; operators: slots 1-4 at register +0, +8, +4, +12
	moveq	#4-1,d5
.op	move.w	(a1)+,d4
	add.w	d6,d4			; this operator's register offset
	move.w	d0,d2			; phase step: (fnum * 2 << block) >> 2,
	and.l	#$7ff,d2		; + detune, & $1FFFF, * multiple / 2
	add.w	d2,d2
	move.w	d0,d3
	lsr.w	#8,d3
	lsr.w	#3,d3			; block
	lsl.l	d3,d2
	lsr.l	#2,d2
	moveq	#0,d7
	move.b	$30(a2,d4.w),d7		; DT / MUL
	move.w	d7,d3
	lsr.w	#4,d3
	and.w	#3,d3
	lea	sy_detune(pc),a3	; [keycode][detune & 3]
	lea	(a3,d1.w*4),a3
	move.b	(a3,d3.w),d3
	ext.w	d3
	ext.l	d3
	btst	#6,d7			; (detune bit 2: down)
	beq.s	.dp
	neg.l	d3
.dp	add.l	d3,d2
	and.l	#$1ffff,d2
	and.w	#15,d7
	add.w	d7,d7
	bne.s	.m
	moveq	#1,d7
.m	mulu.l	d7,d2
	lsr.l	#1,d2
	mulu.l	#SY_STEPK,d2		; (the phase wraps: its high bits go)
	lsr.l	#6,d2
	move.l	d2,OP_STEP(a0)
	moveq	#$7f,d7			; total level << 3
	and.b	$40(a2,d4.w),d7
	lsl.w	#3,d7
	move.w	d7,OP_TL(a0)
	moveq	#0,d2			; sustain level
	move.b	$80(a2,d4.w),d2
	lsr.b	#4,d2
	move.w	d2,d3
	addq.w	#1,d3
	and.w	#$10,d3
	or.w	d3,d2
	lsl.w	#5,d2
	move.w	d2,OP_SL(a0)
	moveq	#0,d3			; key scaling: keycode >> (3 - KS)
	move.b	$50(a2,d4.w),d3
	lsr.b	#6,d3
	eor.b	#3,d3
	move.w	d1,d2
	lsr.w	d3,d2
	moveq	#31,d3			; attack
	and.b	$50(a2,d4.w),d3
	add.w	d3,d3
	bsr	.rate
	move.b	d3,OP_RATE(a0)
	moveq	#31,d3			; decay
	and.b	$60(a2,d4.w),d3
	add.w	d3,d3
	bsr	.rate
	move.b	d3,OP_RATE+1(a0)
	moveq	#31,d3			; sustain
	and.b	$70(a2,d4.w),d3
	add.w	d3,d3
	bsr	.rate
	move.b	d3,OP_RATE+2(a0)
	moveq	#15,d3			; release
	and.b	$80(a2,d4.w),d3
	lsl.w	#2,d3
	addq.w	#2,d3
	bsr	.rate
	move.b	d3,OP_RATE+3(a0)
	add.w	OP_ATT(a0),d7		; the level for the segment: (att + TL) << 2
	cmp.w	#$3ff,d7
	bls.s	.lv
	move.w	#$3ff,d7
.lv	lsl.w	#2,d7
	move.w	d7,OP_LVL(a0)
	lea	OP_SIZE(a0),a0
	dbf	d5,.op
	lea	CH_SIZE-4*OP_SIZE(a0),a0
	bra.s	.nx
.nch	lea	CH_SIZE(a0),a0
.nx	addq.w	#1,d6			; next channel (chip 1's at 256 + 0-2)
	cmp.w	#3,d6
	bne.s	.n3
	move.w	#256,d6
.n3	cmp.w	#256+3,d6
	bne	.ch
	move.b	SY_DIRTY+3(a5),d0
	or.b	SY_DIRTY+7(a5),d0
	beq.s	.r0
	clr.b	SY_DIRTY+3(a5)
	clr.b	SY_DIRTY+7(a5)
	bra	sy_ssg_params
; d3 = raw rate (0: none), d2 = key scaling -> d3 = the rate, 0-63
.rate	tst.w	d3
	beq.s	.r0
	add.w	d2,d3
	cmp.w	#63,d3
	bls.s	.r0
	moveq	#63,d3
.r0	rts

; the SSG: tone steps, levels, mixer; noise steps
sy_ssg_params:
	lea	SY_SG(a5),a0
	lea	ym_regs(pc),a2
	lea	sy_ssgvol(pc),a3
	moveq	#0,d6			; chip
.c	moveq	#0,d4			; channel
.t	moveq	#0,d0			; period
	move.b	1(a2,d4.w*2),d0
	and.w	#15,d0
	lsl.w	#8,d0
	move.b	(a2,d4.w*2),d0
	bsr.s	.step
	move.l	d1,SG_STEP(a0)
	moveq	#15,d0
	and.b	8(a2,d4.w),d0
	move.w	(a3,d0.w*2),SG_VOL(a0)
	move.b	7(a2),d0		; mixer: bits 0-2 tone off, 3-5 noise off
	moveq	#0,d1
	btst	d4,d0
	bne.s	.nt
	bset	#0,d1
.nt	addq.w	#3,d4
	btst	d4,d0
	bne.s	.nn
	bset	#1,d1
.nn	subq.w	#3,d4
	move.w	d1,SG_MODE(a0)
	lea	SG_SIZE(a0),a0
	addq.w	#1,d4
	cmp.w	#3,d4
	bne.s	.t
	moveq	#31,d0			; noise period
	and.b	6(a2),d0
	bsr.s	.step
	move.l	d1,SY_NSTEP(a5,d6.w*4)
	lea	256(a2),a2
	addq.w	#1,d6
	cmp.w	#2,d6
	bne.s	.c
	rts
; d0 = period (0 as 1) -> d1 = the step (a cycle a sample at most)
.step	tst.w	d0
	bne.s	.p
	moveq	#1,d0
.p	move.l	#SY_SSGK,d1
	divu.l	d0,d1
	cmp.l	#$10000000,d1
	blo.s	.ps
	moveq	#-1,d1
	rts
.ps	lsl.l	#4,d1
	rts

; d0 = output samples in the segment: envelopes stepped by their average
; rates for the envelope clocks in it
sy_envelopes:
	move.l	SY_ENVF(a5),d1
	mulu.w	#SY_ECLK>>4,d0		; (clocks << 12)
	lsl.l	#4,d0
	add.l	d0,d1
	cmp.l	#SY_ENVMIN<<16,d1	; (a few at least: short segments add up)
	bhs.s	.go0
	move.l	d1,SY_ENVF(a5)
	rts
.go0	move.l	d1,d0
	clr.w	d0			; whole clocks << 16
	sub.l	d0,d1
	move.l	d1,SY_ENVF(a5)
	swap	d0			; d0 = clocks
	tst.w	d0
	beq	.x
	lea	SY_CH(a5),a0
	lea	sy_envavg(pc),a1	; per rate: attenuation per clock << 16
	moveq	#6-1,d6
.ch	moveq	#4-1,d5
	moveq	#0,d4			; (operators heard: bit 3 - operator)
.op	moveq	#0,d1
	move.b	OP_STATE(a0),d1
	move.l	OP_ATT(a0),d2
	cmp.l	#$3ff<<16,d2		; (released and silent: no change)
	bne.s	.go
	cmp.b	#ST_RELEASE,d1
	beq	.skip
.go	cmp.b	#ST_SUSTAIN,d1		; (sustained at rate 0: none either)
	bne.s	.go2
	tst.b	OP_RATE+ST_SUSTAIN(a0)
	beq	.done
.go2	cmp.b	#ST_ATTACK,d1
	bne.s	.na
	tst.l	d2			; attack done -> decay
	bne.s	.at
	moveq	#ST_DECAY,d1
	bra.s	.na
.at	moveq	#0,d3
	move.b	OP_RATE(a0),d3
	cmp.w	#62,d3
	blo.s	.a1
	moveq	#0,d2
	bra.s	.ad
.a1	move.l	(a1,d3.w*4),d3		; attack: att -= (att + 1) * avg / 16 a clock
	beq.s	.ad
	move.w	d0,-(sp)
	subq.w	#1,d0
.al	move.l	d2,d7
	add.l	#$10000,d7
	clr.w	d7
	swap	d7
	mulu.l	d3,d7
	lsr.l	#4,d7
	sub.l	d7,d2
	bpl.s	.ap
	moveq	#0,d2
	bra.s	.ae
.ap	dbf	d0,.al
.ae	move.w	(sp)+,d0
.ad	move.l	d2,OP_ATT(a0)
	bra.s	.done
.na	cmp.b	#ST_DECAY,d1		; decay -> sustain at the sustain level
	bne.s	.ns
	move.w	OP_ATT(a0),d3
	cmp.w	OP_SL(a0),d3
	blo.s	.ns
	moveq	#ST_SUSTAIN,d1
.ns	move.b	d1,OP_STATE(a0)
	moveq	#0,d3
	move.b	OP_RATE(a0,d1.w),d3
	move.l	(a1,d3.w*4),d3
	mulu.l	d0,d3			; (d0: a word, clear above)
	add.l	d3,d2
	cmp.l	#$3ff<<16,d2
	bls.s	.dn
	move.l	#$3ff<<16,d2
.dn	move.l	d2,OP_ATT(a0)
.done	move.w	OP_ATT(a0),d1		; the level now: (att + TL) << 2
	add.w	OP_TL(a0),d1
	cmp.w	#$380,d1		; (heard?)
	bhi.s	.q
	bset	d5,d4
.q	cmp.w	#$3ff,d1
	bls.s	.lv
	move.w	#$3ff,d1
.lv	lsl.w	#2,d1
	move.w	d1,OP_LVL(a0)
.skip	lea	OP_SIZE(a0),a0
	dbf	d5,.op
	move.w	CH_ALG-4*OP_SIZE(a0),d1	; the channel heard: any carrier
	and.b	sy_carriers(pc,d1.w),d4
	sne	d4
	ext.w	d4
	move.w	d4,CH_LIVE-4*OP_SIZE(a0)
	lea	CH_SIZE-4*OP_SIZE(a0),a0
	dbf	d6,.ch
.x	rts
; each algorithm's carriers (bit 3 - operator)
sy_carriers:	dc.b	%0001,%0001,%0001,%0001,%0101,%0111,%0111,%1111

; d0 = samples: the FM channels and the SSG added into the mix at a4
sy_segment:
	and.l	#$ffff,d0
	move.l	d0,d7
	lea	SY_CH(a5),a0
	moveq	#6-1,d6
.ch	tst.w	CH_LIVE(a0)
	beq.s	.n
	movem.l	d6-d7/a0/a4-a5,-(sp)
	move.w	CH_ALG(a0),d0
	move.w	sy_algs(pc,d0.w*2),d0
	jsr	sy_algs(pc,d0.w)
	movem.l	(sp)+,d6-d7/a0/a4-a5
.n	lea	CH_SIZE(a0),a0
	dbf	d6,.ch
	bra	sy_ssg
sy_algs:
	dc.w	sy_alg0-sy_algs,sy_alg1-sy_algs,sy_alg2-sy_algs,sy_alg3-sy_algs
	dc.w	sy_alg4-sy_algs,sy_alg5-sy_algs,sy_alg6-sy_algs,sy_alg7-sy_algs

; In a channel's loop: d0-d3 the operators' phases, d6 / d7 (low words)
; operator 1's last two outputs, d7's high word the samples left - 1; a6 the
; sine, a5 the volumes (attenuation -> volume, negative below), a4 the mix.
SY_LOOP	macro
	move.w	d7,d4
	subq.w	#1,d4
	swap	d4
	move.w	CH_FB2(a0),d4
	move.l	d4,d7
	move.w	CH_FB1(a0),d6
	move.l	0*OP_SIZE+OP_PHASE(a0),d0
	move.l	1*OP_SIZE+OP_PHASE(a0),d1
	move.l	2*OP_SIZE+OP_PHASE(a0),d2
	move.l	3*OP_SIZE+OP_PHASE(a0),d3
	lea	SY_SIN(a5),a6
	lea	SY_EXP(a5),a5
	endm
SY_NEXT	macro
	sub.l	#$10000,d7
	bcc	\1
	move.l	d0,0*OP_SIZE+OP_PHASE(a0)
	move.l	d1,1*OP_SIZE+OP_PHASE(a0)
	move.l	d2,2*OP_SIZE+OP_PHASE(a0)
	move.l	d3,3*OP_SIZE+OP_PHASE(a0)
	move.w	d6,CH_FB1(a0)
	move.w	d7,CH_FB2(a0)
	rts
	endm

; one operator: \1 = its phase register, \2 = modulation (word, or none),
; \3 = its offset in the channel, result -> \4. Uses d4.
SY_OP	macro
	move.l	\1,d4
	swap	d4			; the 10-bit sine index (and junk above)
	ifnc	"\2",""
	add.w	\2,d4
	endif
	and.w	#$3ff,d4
	move.w	(a6,d4.w*2),\4
	add.w	\3+OP_LVL(a0),\4
	move.w	(a5,\4.w*2),\4
	add.l	\3+OP_STEP(a0),\1
	endm

; operator 1, its feedback: (the last two outputs) >> shift -> \1; uses d5
SY_FB	macro
	move.w	d6,d4
	add.w	d7,d4
	move.w	CH_FBSH(a0),d5
	asr.w	d5,d4
	and.w	CH_FBMASK(a0),d4
	move.w	d4,d5
	SY_OP	d0,d5,0*OP_SIZE,\1
	move.w	d6,d7
	move.w	\1,d6
	endm

; a sum of outputs kept to the chip's 14 bits
SY_CLIP	macro
	cmp.w	#8191,\1
	ble.s	.c1\@
	move.w	#8191,\1
.c1\@	cmp.w	#-8192,\1
	bge.s	.c2\@
	move.w	#-8192,\1
.c2\@
	endm

; the mix: \1 (a channel's output) / 4, added
SY_MIXOUT macro
	asr.w	#2,\1
	add.w	\1,(a4)+
	endm

; the algorithms (O1-O4: operators 1-4; modulation is an output / 2).
; Free: a1, a2, a3, d5.
sy_alg0:				; O1 -> O2 -> O3 -> O4
	SY_LOOP
.l	SY_FB	a1
	move.w	a1,d5
	asr.w	#1,d5
	SY_OP	d1,d5,1*OP_SIZE,d5
	asr.w	#1,d5
	SY_OP	d2,d5,2*OP_SIZE,d5
	asr.w	#1,d5
	SY_OP	d3,d5,3*OP_SIZE,d5
	SY_MIXOUT d5
	SY_NEXT	.l
sy_alg1:				; (O1 + O2) -> O3 -> O4
	SY_LOOP
.l	SY_FB	a1
	SY_OP	d1,,1*OP_SIZE,d5
	add.w	a1,d5
	asr.w	#1,d5
	SY_OP	d2,d5,2*OP_SIZE,d5
	asr.w	#1,d5
	SY_OP	d3,d5,3*OP_SIZE,d5
	SY_MIXOUT d5
	SY_NEXT	.l
sy_alg2:				; (O1 + (O2 -> O3)) -> O4
	SY_LOOP
.l	SY_FB	a1
	SY_OP	d1,,1*OP_SIZE,d5
	asr.w	#1,d5
	SY_OP	d2,d5,2*OP_SIZE,d5
	add.w	a1,d5
	asr.w	#1,d5
	SY_OP	d3,d5,3*OP_SIZE,d5
	SY_MIXOUT d5
	SY_NEXT	.l
sy_alg3:				; ((O1 -> O2) + O3) -> O4
	SY_LOOP
.l	SY_FB	a1
	move.w	a1,d5
	asr.w	#1,d5
	SY_OP	d1,d5,1*OP_SIZE,d5
	move.w	d5,a2
	SY_OP	d2,,2*OP_SIZE,d5
	add.w	a2,d5
	asr.w	#1,d5
	SY_OP	d3,d5,3*OP_SIZE,d5
	SY_MIXOUT d5
	SY_NEXT	.l
sy_alg4:				; (O1 -> O2) + (O3 -> O4)
	SY_LOOP
.l	SY_FB	a1
	move.w	a1,d5
	asr.w	#1,d5
	SY_OP	d1,d5,1*OP_SIZE,d5
	move.w	d5,a2
	SY_OP	d2,,2*OP_SIZE,d5
	asr.w	#1,d5
	SY_OP	d3,d5,3*OP_SIZE,d5
	add.w	a2,d5
	SY_CLIP	d5
	SY_MIXOUT d5
	SY_NEXT	.l
sy_alg5:				; O1 -> O2, O3, O4
	SY_LOOP
.l	SY_FB	a1
	move.w	a1,d5
	asr.w	#1,d5
	move.w	d5,a3
	SY_OP	d1,d5,1*OP_SIZE,d5
	move.w	d5,a2
	SY_OP	d2,a3,2*OP_SIZE,d5
	add.w	d5,a2
	SY_OP	d3,a3,3*OP_SIZE,d5
	add.w	a2,d5
	SY_CLIP	d5
	SY_MIXOUT d5
	SY_NEXT	.l
sy_alg6:				; (O1 -> O2) + O3 + O4
	SY_LOOP
.l	SY_FB	a1
	move.w	a1,d5
	asr.w	#1,d5
	SY_OP	d1,d5,1*OP_SIZE,d5
	move.w	d5,a2
	SY_OP	d2,,2*OP_SIZE,d5
	add.w	d5,a2
	SY_OP	d3,,3*OP_SIZE,d5
	add.w	a2,d5
	SY_CLIP	d5
	SY_MIXOUT d5
	SY_NEXT	.l
sy_alg7:				; O1 + O2 + O3 + O4
	SY_LOOP
.l	SY_FB	a1
	SY_OP	d1,,1*OP_SIZE,d5
	move.w	d5,a2
	add.w	a1,a2
	SY_OP	d2,,2*OP_SIZE,d5
	add.w	d5,a2
	SY_OP	d3,,3*OP_SIZE,d5
	add.w	a2,d5
	SY_CLIP	d5
	SY_MIXOUT d5
	SY_NEXT	.l

; the SSG's six channels into the mix (d7 samples at a4): each a square wave
; +- its level, gated by the noise (per chip: its bits for the segment first)
sy_ssg:
	moveq	#0,d6			; chip
.chip	lea	SY_SG(a5),a0
	move.w	d6,d0
	mulu.w	#3*SG_SIZE,d0
	add.w	d0,a0
	moveq	#0,d0			; any channel heard with noise?
	moveq	#3-1,d1
	move.l	a0,a2
.w	tst.w	SG_VOL(a2)
	beq.s	.w1
	btst	#1,SG_MODE+1(a2)
	beq.s	.w1
	moveq	#1,d0
.w1	lea	SG_SIZE(a2),a2
	dbf	d1,.w
	tst.w	d0
	beq.s	.nn
	lea	SY_NBUF(a5),a1		; the noise: a byte a sample, -1 = on
	move.w	d7,d5
	subq.w	#1,d5
	move.l	SY_NOISE(a5,d6.w*4),d3
	move.l	SY_NPHASE(a5,d6.w*4),d4
	move.l	SY_NSTEP(a5,d6.w*4),a3
.ns	add.l	a3,d4			; an LFSR step per period
	bcc.s	.nq
	move.l	d3,d0			; (17 bits: bit 0 ^ bit 3 in at the top)
	lsr.l	#3,d0
	eor.l	d3,d0
	and.w	#1,d0
	swap	d0
	clr.w	d0
	add.l	d0,d0
	eor.l	d0,d3
	lsr.l	#1,d3
.nq	moveq	#1,d0
	and.w	d3,d0
	neg.b	d0
	move.b	d0,(a1)+
	dbf	d5,.ns
	move.l	d3,SY_NOISE(a5,d6.w*4)
	move.l	d4,SY_NPHASE(a5,d6.w*4)
.nn	moveq	#3-1,d1			; each channel heard
	move.l	a0,a2
.ch	move.w	SG_VOL(a2),d2
	beq	.cn
	move.l	a4,a1
	lea	SY_NBUF(a5),a3
	move.w	d7,d5
	subq.w	#1,d5
	move.l	SG_PHASE(a2),d3
	move.l	SG_STEP(a2),d4
	move.w	SG_MODE(a2),d0
	subq.w	#1,d0
	beq.s	.tone
	subq.w	#1,d0
	beq.s	.noise
	subq.w	#1,d0
	beq.s	.both
.const	add.w	d2,(a1)+		; neither: always on
	dbf	d5,.const
	bra.s	.skip
.noise	tst.b	(a3)+
	beq.s	.n0
	add.w	d2,(a1)+
	dbf	d5,.noise
	bra.s	.skip
.n0	sub.w	d2,(a1)+
	dbf	d5,.noise
.skip	move.l	d4,d0			; (the tone moves on all the same)
	mulu.l	d7,d0
	add.l	d0,d3
	bra.s	.cd
.tone	add.l	d4,d3			; on in the first half of a cycle
	bmi.s	.t0
	add.w	d2,(a1)+
	dbf	d5,.tone
	bra.s	.cd
.t0	sub.w	d2,(a1)+
	dbf	d5,.tone
	bra.s	.cd
.both	add.l	d4,d3
	bmi.s	.b0
	tst.b	(a3)+
	beq.s	.b1
	add.w	d2,(a1)+
	dbf	d5,.both
	bra.s	.cd
.b0	addq.l	#1,a3
.b1	sub.w	d2,(a1)+
	dbf	d5,.both
.cd	move.l	d3,SG_PHASE(a2)
.cn	lea	SG_SIZE(a2),a2
	dbf	d1,.ch
	addq.w	#1,d6
	cmp.w	#2,d6
	bne	.chip
	rts

sy_slots:	dc.w	0,8,4,12		; slots 1-4 -> register offset
sy_mem:		dc.l	0
sy_detune:					; [keycode][detune 0-3]
	dc.b	0,0,1,2, 0,0,1,2, 0,0,1,2, 0,0,1,2, 0,1,2,2, 0,1,2,3, 0,1,2,3, 0,1,2,3
	dc.b	0,1,2,4, 0,1,3,4, 0,1,3,4, 0,1,3,5, 0,2,4,5, 0,2,4,6, 0,2,4,6, 0,2,5,7
	dc.b	0,2,5,8, 0,3,6,8, 0,3,6,9, 0,3,7,10, 0,4,8,11, 0,4,8,12, 0,4,9,13, 0,5,10,14
	dc.b	0,5,11,16, 0,6,12,17, 0,6,13,19, 0,7,14,20, 0,8,16,22, 0,8,16,22, 0,8,16,22, 0,8,16,22
	even
	include	"fm_tables.i"		; (tools/sound/fm_tables.py)
