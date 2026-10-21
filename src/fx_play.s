; Black Tiger AGA - sound effects as samples (an A1200 without fast RAM: no
; room or time for the sound program and its mixer). The game's sound
; commands start packed samples (tools/sound/effects.py: blocks of 32
; samples, a step table and 16 bytes of 4-bit steps) on Paula's channels,
; one effect a channel; channel 0's block interrupt unpacks the next chunk of
; each, double-buffered as the sound player does (src/sound_play.s).
;
;   fx_init     a0 = the output buffers (chip RAM, FX_BUFSIZE), a1 = the bank
;   fx_command  d0.b = a command (port 0); call with interrupts masked
;
; Commands: $00 and $1F stop everything, $44 the drone ($3C), $45 the loops;
; an effect playing already starts again on its channel, else a free
; channel, else the one that started longest ago (loops last).

FX_CHUNK	equ	64			; samples per chunk: 10.5 ms (2 blocks)
FX_BLOCK	equ	32
FX_BUFSIZE	equ	4*2*FX_CHUNK

	rsreset				; a channel
FC_PTR		rs.l	1		; next block (0: silent)
FC_LOOP		rs.l	1		; the loop's first block (0: one-shot)
FC_AGE		rs.l	1		; when it started
FC_LEFT		rs.w	1		; blocks left
FC_LOOPN	rs.w	1		; blocks in the loop
FC_VAL		rs.b	1		; the running value
FC_LOOPV	rs.b	1		; ... at the loop start
FC_CMD		rs.b	1		; the effect
FC_VOL		rs.b	1		; its Paula volume
FC_SIZE		rs.b	0

	rsreset
FV_CHAN		rs.b	4*FC_SIZE
FV_BUF		rs.l	1
FV_BANK		rs.l	1
FV_STARTS	rs.l	1		; effects started (FC_AGE)
FV_HALF		rs.w	1		; the half being filled next
FV_NEXTVOL	rs.b	4		; per channel: the volume for the half filled
FV_SIZE		rs.b	0

fx_init:
	movem.l	d0-d7/a0-a6,-(sp)
	lea	fx_vars(pc),a4
	move.l	a0,FV_BUF(a4)
	move.l	a1,FV_BANK(a4)
	move.w	#1,FV_HALF(a4)		; (half 0 plays first)
	move.w	#FX_BUFSIZE-1,d0
.cb	clr.b	(a0)+
	dbf	d0,.cb
	lea	CUSTOM,a6
	move.w	#$000f,DMACON(a6)	; audio off while set up
	move.l	FV_BUF(a4),a0
	lea	AUD0LC(a6),a1
	moveq	#4-1,d0
.ch	move.l	a0,(a1)			; channel n: blocks of a chunk, half 0 first
	move.w	#FX_CHUNK/2,4(a1)
	move.w	#FX_PERIOD,6(a1)
	clr.w	8(a1)
	lea	16(a1),a1
	lea	2*FX_CHUNK(a0),a0
	dbf	d0,.ch
	movec	vbr,a0
	lea	fx_irq(pc),a1
	move.l	a1,$70(a0)
	move.w	#$0780,INTREQ(a6)
	move.w	#$c080,INTENA(a6)	; channel 0's block interrupt
	move.w	#$800f,DMACON(a6)
	movem.l	(sp)+,d0-d7/a0-a6
	rts

; channel 0 starts a block: the half filled last plays now (its volumes);
; point every channel at the other half and fill it
fx_irq:
	movem.l	d0-d7/a0-a6,-(sp)
	lea	CUSTOM,a6
	move.w	#$0080,INTREQ(a6)
	move.w	#$0080,INTREQ(a6)
	lea	fx_vars(pc),a4
	moveq	#0,d0
	move.b	FV_NEXTVOL(a4),d0
	move.w	d0,AUD0LC+8(a6)
	move.b	FV_NEXTVOL+1(a4),d0
	move.w	d0,AUD0LC+$18(a6)
	move.b	FV_NEXTVOL+2(a4),d0
	move.w	d0,AUD0LC+$28(a6)
	move.b	FV_NEXTVOL+3(a4),d0
	move.w	d0,AUD0LC+$38(a6)
	move.w	FV_HALF(a4),d0
	mulu.w	#FX_CHUNK,d0
	move.l	FV_BUF(a4),a3
	add.l	d0,a3
	move.l	a3,a0
	lea	AUD0LC(a6),a1
	moveq	#4-1,d1
.lc	move.l	a0,(a1)
	lea	16(a1),a1
	lea	2*FX_CHUNK(a0),a0
	dbf	d1,.lc
	move.l	FV_BANK(a4),a2
	lea	FX_COUNT*FX_REC(a2),a2	; the step tables
	lea	FV_CHAN(a4),a5
	moveq	#4-1,d7
.ch	bsr	fx_fill
	moveq	#3,d0			; (channel 3 - d7)
	sub.w	d7,d0
	move.b	d5,FV_NEXTVOL(a4,d0.w)
	lea	FC_SIZE(a5),a5
	lea	2*FX_CHUNK(a3),a3
	dbf	d7,.ch
	eori.w	#1,FV_HALF(a4)
	movem.l	(sp)+,d0-d7/a0-a6
	rte

; a5 = channel, a3 = its half, a2 = the step tables: FX_CHUNK samples ->
; d5 = its volume (0: silent)
fx_fill:
	moveq	#0,d5
	move.l	FC_PTR(a5),d0
	beq	.zero
	move.l	d0,a0
	move.b	FC_VAL(a5),d2
	moveq	#0,d3
	moveq	#0,d4
	moveq	#FX_CHUNK/FX_BLOCK-1,d6
.blk	tst.w	FC_LEFT(a5)		; at the end: the loop, or silence
	bne	.dec
	move.l	FC_LOOP(a5),d0
	beq	.stop
	move.l	d0,a0
	move.w	FC_LOOPN(a5),FC_LEFT(a5)
	move.b	FC_LOOPV(a5),d2
.dec	subq.w	#1,FC_LEFT(a5)
	moveq	#0,d0
	move.b	(a0)+,d0		; the block's table
	cmp.b	#FX_SILENT,d0
	bne	.tab
	moveq	#FX_BLOCK-1,d1
.sil	move.b	d2,(a3)+
	dbf	d1,.sil
	bra	.nb
.tab	lsl.w	#4,d0
	lea	(a2,d0.w),a1
	moveq	#FX_BLOCK/2-1,d1
.d	move.b	(a0)+,d3		; two steps: high nibble first
	move.b	d3,d4
	lsr.b	#4,d4
	add.b	(a1,d4.w),d2
	move.b	d2,(a3)+
	and.b	#15,d3
	add.b	(a1,d3.w),d2
	move.b	d2,(a3)+
	dbf	d1,.d
.nb	dbf	d6,.blk
	move.l	a0,FC_PTR(a5)
	move.b	d2,FC_VAL(a5)
	move.b	FC_VOL(a5),d5
	rts
.stop	clr.l	FC_PTR(a5)		; the rest of the chunk silent
	addq.w	#1,d6
	lsl.w	#5,d6			; (blocks -> samples)
	subq.w	#1,d6
.z	clr.b	(a3)+
	dbf	d6,.z
	move.b	FC_VOL(a5),d5		; (the end of it still plays)
	rts
.zero	moveq	#FX_CHUNK/4-1,d0
.zl	clr.l	(a3)+
	dbf	d0,.zl
	rts

; d0.b = a sound command (interrupts masked)
fx_command:
	movem.l	d0-d3/a0-a1/a4-a5,-(sp)
	lea	fx_vars(pc),a4
	and.w	#$ff,d0
	cmp.b	#$00,d0			; stop everything
	beq	.all
	cmp.b	#$1f,d0
	beq	.all
	cmp.b	#$44,d0			; stop the drone
	bne	.n44
	moveq	#$3c,d1
	bsr	fx_stop
	bra	.x
.n44	cmp.b	#$45,d0			; stop the loops, then play
	bne	.play
	moveq	#$14,d1
	bsr	fx_stop
	moveq	#$3c,d1
	bsr	fx_stop
.play	cmp.w	#FX_COUNT,d0
	bhs	.x
	move.l	FV_BANK(a4),a0
	move.w	d0,d1
	mulu.w	#FX_REC,d1
	add.w	d1,a0			; its record
	tst.l	(a0)
	beq	.x			; (no sample: e.g. music)
	bsr	fx_channel		; -> a5
	move.l	FV_BANK(a4),d1
	add.l	(a0),d1
	move.l	d1,FC_PTR(a5)
	move.w	4(a0),FC_LEFT(a5)
	clr.l	FC_LOOP(a5)
	move.l	6(a0),d1
	beq	.nl
	add.l	FV_BANK(a4),d1
	move.l	d1,FC_LOOP(a5)
.nl	move.w	10(a0),FC_LOOPN(a5)
	move.b	12(a0),FC_LOOPV(a5)
	move.b	13(a0),FC_VOL(a5)
	clr.b	FC_VAL(a5)
	move.b	d0,FC_CMD(a5)
	addq.l	#1,FV_STARTS(a4)
	move.l	FV_STARTS(a4),FC_AGE(a5)
	bra	.x
.all	moveq	#4-1,d1
	lea	FV_CHAN(a4),a5
.al	clr.l	FC_PTR(a5)
	lea	FC_SIZE(a5),a5
	dbf	d1,.al
.x	movem.l	(sp)+,d0-d3/a0-a1/a4-a5
	rts

; d1.b = an effect: stop it wherever it plays
fx_stop:
	movem.l	d2/a5,-(sp)
	lea	FV_CHAN(a4),a5
	moveq	#4-1,d2
.s	cmp.b	FC_CMD(a5),d1
	bne	.n
	clr.l	FC_PTR(a5)
.n	lea	FC_SIZE(a5),a5
	dbf	d2,.s
	movem.l	(sp)+,d2/a5
	rts

; d0 = effect -> a5 = the channel for it: where it plays already, a free
; one, or the one that started longest ago (one-shots before loops)
fx_channel:
	movem.l	d1-d3/a0,-(sp)
	lea	FV_CHAN(a4),a5
	moveq	#4-1,d1
.same	tst.l	FC_PTR(a5)
	beq	.ns
	cmp.b	FC_CMD(a5),d0
	beq	.got
.ns	lea	FC_SIZE(a5),a5
	dbf	d1,.same
	lea	FV_CHAN(a4),a5
	moveq	#4-1,d1
.free	tst.l	FC_PTR(a5)
	beq	.got
	lea	FC_SIZE(a5),a5
	dbf	d1,.free
	lea	FV_CHAN(a4),a0		; all busy: the oldest (a loop counts as
	moveq	#-1,d2			; newer than any one-shot)
	moveq	#4-1,d1
.old	move.l	FC_AGE(a0),d3
	tst.l	FC_LOOP(a0)
	beq	.os
	bset	#31,d3
.os	cmp.l	d2,d3
	bhs	.on
	move.l	d3,d2
	move.l	a0,a5
.on	lea	FC_SIZE(a0),a0
	dbf	d1,.old
.got	movem.l	(sp)+,d1-d3/a0
	rts

	cnop	0,4
fx_vars:	ds.b	FV_SIZE
		even
