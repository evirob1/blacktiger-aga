; Black Tiger AGA - music for an A1200 without fast RAM: the tunes as notes
; on Paula's four channels (tools/sound/tracker.py makes them from the ROM,
; and models this player: its Player class), with the sound effects
; (src/fx_play.s's samples) taking a channel while they play.
;
;   trk_init     a0 = the bank (chip RAM), a1 = the effects' bank, a2 = the
;                effects' output buffers (chip RAM, FX_BUFSIZE), a3 = the
;                tunes' buffer (TRK_BUF): the timer (CIA-B timer A, level 6:
;                a tick, TRK_TICK E clocks - the sound program's own tempo)
;                and the channels' interrupts (level 4, the effects) running
;   trk_command  d0.b = a sound command (port 0)
;   trk_music    d0.b: not 0: tunes play, 0: they don't (and stop)
;
; A tick: the voices' notes due are given channels (the most important
; first: a free channel, a released one - the quietest -, else the channel
; of a lower priority note, unless a doubling / echo voice); a channel given
; a note stops (DMA off) and starts it the tick after, and sets its loop the
; tick after that; every tick its volume from the note's level and fades.
; The bank's format: tools/sound/tracker.py (write_bank).

CIAB_TALO	equ	$bfd400
CIAB_TAHI	equ	$bfd500
CIAB_ICR	equ	$bfdd00
CIAB_CRA	equ	$bfde00

; the bank
TB_SAMPLES	equ	0
TB_BUF		equ	2
TB_TUNES	equ	4
TB_RECS		equ	132
	rsreset				; a sample
TS_OFF		rs.l	1
TS_LEN		rs.w	1		; words
TS_LOOP		rs.w	1		; words, $ffff: none
TS_LLEN		rs.w	1
TS_DR		rs.w	1		; rate << 8 | key scaling
TS_TOTAL	rs.w	1
TS_SR		rs.w	1
TS_ATT		rs.b	1
		rs.b	1
TS_REL		rs.w	8		; per block
		rs.w	1
TS_SIZE		rs.b	0
	rsreset				; a tune
TU_LOOP		rs.w	1		; $ffff: none
TU_END		rs.w	1
TU_STREAMS	rs.w	12		; per voice: stream, loop (offsets in the streams)
TU_PRESETS	rs.w	1
		rs.w	1
TU_SIZE		rs.b	0
	rsreset				; a preset
TP_SAMPLE	rs.w	1
TP_PERIOD	rs.w	1
TP_BLOCK	rs.b	1
TP_KC		rs.b	1
TP_SIZE		rs.b	0

	rsreset				; a voice
VO_PTR		rs.l	1
VO_LP		rs.l	1
VO_T		rs.w	1		; its last note's time
VO_CACHE	rs.w	6		; (gap, length) x 3, the most recent first
VO_NC		rs.w	1		; pairs in it
VO_LVL		rs.b	1
VO_DONE		rs.b	1
VO_NT0		rs.w	1		; its next note: time,
VO_NDUR		rs.w	1		; length,
VO_NPRE		rs.w	1		; preset,
VO_NLVL		rs.b	1		; level,
VO_NMINOR	rs.b	1		; a doubling / echo voice,
VO_NPRI		rs.w	1		; priority
VO_SIZE		rs.b	0

	rsreset				; a channel
TC_MODE		rs.b	1		; 0: music (or idle), 2: an effect
TC_STATE	rs.b	1		; 0 off, 1 given a note (starts next tick), 2 started, 3 playing
TC_LVL		rs.b	1
TC_ONE		rs.b	1		; a one-shot sample
TC_SMP		rs.l	1
TC_PRE		rs.l	1
TC_START	rs.w	1
TC_T1		rs.w	1		; key off (the tick)
TC_DUR		rs.w	1
TC_LOOPT	rs.w	1		; ticks to the loop / the end
TC_ENDT		rs.w	1
TC_REL		rs.w	1		; attenuation (1/256 TL steps)
TC_FADED	rs.w	1
TC_PRI		rs.w	1
TC_SIZE		rs.b	0

	rsreset
TV_BANK		rs.l	1
TV_TUNE		rs.l	1		; the tune playing, or 0
TV_PRE		rs.l	1		; its presets
TV_BUF		rs.l	1		; its streams, unpacked
TV_FXBANK	rs.l	1
TV_FXBUF	rs.l	1
TV_POS		rs.w	1		; time in the tune
TV_TICK		rs.w	1		; time for the channels
TV_ON		rs.b	1		; tunes play
TV_NNEW		rs.b	1
TV_NEW		rs.l	6		; the voices with a note this tick (by priority)
TV_VOICES	rs.b	6*VO_SIZE
TV_CHANS	rs.b	4*TC_SIZE
TV_SIZE		rs.b	0

QUIET		equ	53*256		; 40 dB down: the channel is free

trk_init:
	movem.l	d0-d7/a0-a6,-(sp)
	lea	trk_vars(pc),a4
	move.l	a0,TV_BANK(a4)
	move.l	a1,TV_FXBANK(a4)
	move.l	a2,TV_FXBUF(a4)
	move.l	a3,TV_BUF(a4)
	clr.l	TV_TUNE(a4)
	st	TV_ON(a4)
	lea	fx_vars(pc),a0		; (the effects' channels: fx_play.s's records)
	move.l	a1,FV_BANK(a0)
	move.l	a2,FV_BUF(a0)
	moveq	#4-1,d0
	lea	FV_CHAN(a0),a0
.fc	clr.l	FC_PTR(a0)
	lea	FC_SIZE(a0),a0
	dbf	d0,.fc
	lea	CUSTOM,a6
	move.w	#$000f,DMACON(a6)
	moveq	#4-1,d0
	lea	AUD0LC(a6),a1
.ch	clr.w	8(a1)
	lea	16(a1),a1
	dbf	d0,.ch
	movec	vbr,a0
	lea	trk_aud(pc),a1
	move.l	a1,$70(a0)
	lea	trk_lev6(pc),a1
	move.l	a1,$78(a0)
	move.w	#$0780,INTREQ(a6)	; (the channels' interrupts: as effects start)
	move.b	#$7f,CIAB_ICR		; CIA-B: timer A only, continuous
	tst.b	CIAB_ICR
	move.b	#0,CIAB_CRA
	move.b	#TRK_TICK&255,CIAB_TALO
	move.b	#TRK_TICK>>8,CIAB_TAHI
	move.b	#$81,CIAB_ICR
	move.b	#$11,CIAB_CRA		; start (force load)
	move.w	#$2000,INTREQ(a6)
	move.w	#$a000,INTENA(a6)
	movem.l	(sp)+,d0-d7/a0-a6
	rts

; level 6: the timer
trk_lev6:
	movem.l	d0-d7/a0-a6,-(sp)
	tst.b	CIAB_ICR		; (read: acknowledged)
	lea	CUSTOM,a6
	move.w	#$2000,INTREQ(a6)
	move.w	#$2000,INTREQ(a6)
	lea	trk_vars(pc),a4
	bsr	trk_tick
	movem.l	(sp)+,d0-d7/a0-a6
	rte

;------------------------------------------------------------------------------
; one tick (a4 = the variables, a6 = CUSTOM)
trk_tick:
	move.l	TV_TUNE(a4),d0
	beq	.chans
	move.l	d0,a0
	move.w	TU_LOOP(a0),d0		; the loop: every voice from its sync
	cmp.w	#$ffff,d0
	beq.s	.chans
	move.w	TV_POS(a4),d1
	cmp.w	TU_END(a0),d1
	bne.s	.chans
	move.w	d0,TV_POS(a4)
	lea	TV_VOICES(a4),a3
	moveq	#6-1,d7
.lv	move.l	VO_LP(a3),VO_PTR(a3)
	sf	VO_DONE(a3)
	bsr	trk_read
	lea	VO_SIZE(a3),a3
	dbf	d7,.lv
.chans	lea	TV_CHANS(a4),a5		; the channels: start, loop, fade
	lea	AUD0LC(a6),a2
	moveq	#0,d7			; channel
.ch	tst.b	TC_MODE(a5)
	bne	.chn			; (an effect's)
	move.b	TC_STATE(a5),d0
	beq	.chn
	cmp.b	#1,d0
	bne.s	.st2
	bsr	ch_start		; given a note last tick: it starts
	bra	.chn
.st2	cmp.b	#2,d0
	bne.s	.st3
	bsr	ch_loop			; its loop (or silence) after the first pass
.st3	bsr	ch_fade
.chn	lea	TC_SIZE(a5),a5
	lea	16(a2),a2
	addq.w	#1,d7
	cmp.w	#4,d7
	bne.s	.ch
	tst.l	TV_TUNE(a4)		; the notes due, by priority
	beq	.x
	clr.b	TV_NNEW(a4)
	lea	TV_VOICES(a4),a3
	moveq	#6-1,d7
.nv	tst.b	VO_DONE(a3)
	bne.s	.nn
	move.w	VO_NT0(a3),d0
	cmp.w	TV_POS(a4),d0
	bne.s	.nn
	bsr	trk_take		; (in order of priority; a later one of the
	bsr	trk_read		; same after an earlier)
	bra.s	.nv
.nn	lea	VO_SIZE(a3),a3
	dbf	d7,.nv
	moveq	#0,d6
.give	cmp.b	TV_NNEW(a4),d6
	beq.s	.x
	move.l	TV_NEW(a4,d6.w*4),a3	; (a copy of the note: its voice moved on)
	bsr	trk_choose
	tst.w	d7
	bmi.s	.ng
	bsr	trk_give
.ng	addq.w	#1,d6
	bra.s	.give
.x	addq.w	#1,TV_POS(a4)
	addq.w	#1,TV_TICK(a4)
	rts

; a3 = a voice whose next note is due: a copy of it into the list, in order
; of priority (after those of the same)
trk_take:
	movem.l	d0-d2/a0-a1,-(sp)
	moveq	#0,d0
	move.b	TV_NNEW(a4),d0
	cmp.w	#6,d0			; (room for six: a note a voice)
	bhs	.full
	lea	trk_notes(pc),a0
	mulu.w	#VO_SIZE,d0
	add.l	d0,a0
	moveq	#VO_SIZE/2-1,d1
	move.l	a3,a1
.cp	move.w	(a1)+,(a0)+
	dbf	d1,.cp
	sub.l	#VO_SIZE,a0		; the copy
	moveq	#0,d0
	move.b	TV_NNEW(a4),d0		; insert: after every one of at least its priority
	move.w	d0,d1
.ins	tst.w	d1
	beq.s	.put
	move.l	TV_NEW-4(a4,d1.w*4),a1
	move.w	VO_NPRI(a1),d2
	cmp.w	VO_NPRI(a0),d2
	bge.s	.put
	move.l	a1,TV_NEW(a4,d1.w*4)
	subq.w	#1,d1
	bra.s	.ins
.put	move.l	a0,TV_NEW(a4,d1.w*4)
	addq.b	#1,TV_NNEW(a4)
.full	movem.l	(sp)+,d0-d2/a0-a1
	rts

; a3 = a note (a voice record's next note) -> d7 = the channel for it, or -1
trk_choose:
	movem.l	d0-d6/a0,-(sp)
	lea	TV_CHANS(a4),a0
	moveq	#0,d7			; free: not given one, not sounding (or
.free	tst.b	TC_MODE(a0)		; released and 40 dB down)
	bne.s	.nf
	bsr	ch_busy
	beq	.x
.nf	lea	TC_SIZE(a0),a0
	addq.w	#1,d7
	cmp.w	#4,d7
	bne.s	.free
	lea	TV_CHANS(a4),a0		; released: the quietest (the first of them)
	moveq	#-1,d6
	moveq	#-1,d5			; (its attenuation)
	moveq	#0,d7
.rel	tst.b	TC_MODE(a0)
	bne.s	.nr
	cmp.b	#1,TC_STATE(a0)
	beq.s	.nr
	tst.b	TC_STATE(a0)
	beq.s	.nr
	move.w	TV_TICK(a4),d0
	sub.w	TC_T1(a0),d0
	bmi.s	.nr
	moveq	#0,d0
	move.w	TC_REL(a0),d0
	cmp.l	d5,d0
	ble.s	.nr
	move.l	d0,d5
	move.w	d7,d6
.nr	lea	TC_SIZE(a0),a0
	addq.w	#1,d7
	cmp.w	#4,d7
	bne.s	.rel
	move.w	d6,d7
	bpl.s	.x
	tst.b	VO_NMINOR(a3)		; a doubling / echo voice: no further
	bne.s	.none
	lea	TV_CHANS(a4),a0		; the lowest priority (the first of them),
	move.w	#$7fff,d5		; if lower than this note's
	moveq	#-1,d6
	moveq	#0,d7
.low	tst.b	TC_MODE(a0)
	bne.s	.nl
	cmp.w	TC_PRI(a0),d5
	ble.s	.nl
	move.w	TC_PRI(a0),d5
	move.w	d7,d6
.nl	lea	TC_SIZE(a0),a0
	addq.w	#1,d7
	cmp.w	#4,d7
	bne.s	.low
	move.w	d6,d7
	bmi.s	.x
	cmp.w	VO_NPRI(a3),d5
	blt.s	.x
.none	moveq	#-1,d7
.x	movem.l	(sp)+,d0-d6/a0
	rts

; a0 = a music channel -> Z set if free (not given a note, not sounding, or
; released and 40 dB down)
ch_busy:
	move.l	d0,-(sp)
	move.b	TC_STATE(a0),d0
	beq.s	.free
	cmp.b	#1,d0
	beq.s	.busy
	move.w	TV_TICK(a4),d0
	sub.w	TC_T1(a0),d0
	bmi.s	.busy
	cmp.w	#QUIET,TC_REL(a0)
	bhs.s	.free
.busy	move.l	(sp)+,d0
	andi.b	#$fb,ccr		; (Z clear)
	rts
.free	move.l	(sp)+,d0
	ori.b	#$04,ccr		; (Z set)
	rts

; a3 = a note, d7 = channel: it stops now, starts next tick
trk_give:
	movem.l	d0-d2/a0-a2,-(sp)
	lea	TV_CHANS(a4),a0
	move.w	d7,d0
	mulu.w	#TC_SIZE,d0
	add.l	d0,a0
	moveq	#1,d0			; DMA off, silent
	lsl.w	d7,d0
	move.w	d0,DMACON(a6)
	lea	AUD0LC(a6),a1
	move.w	d7,d0
	lsl.w	#4,d0
	clr.w	8(a1,d0.w)
	move.b	#1,TC_STATE(a0)
	move.b	VO_NLVL(a3),TC_LVL(a0)
	move.w	VO_NPRI(a3),TC_PRI(a0)
	move.w	VO_NDUR(a3),TC_DUR(a0)
	move.l	TV_PRE(a4),a1		; its preset and sample
	moveq	#0,d0
	move.w	VO_NPRE(a3),d0
	mulu.w	#TP_SIZE,d0
	add.l	d0,a1
	move.l	a1,TC_PRE(a0)
	move.l	TV_BANK(a4),a2
	moveq	#0,d0
	move.w	TP_SAMPLE(a1),d0
	mulu.w	#TS_SIZE,d0
	lea	TB_RECS(a2,d0.l),a2
	move.l	a2,TC_SMP(a0)
	moveq	#0,d0			; ticks to the loop, to the end: words x
	move.w	TS_LOOP(a2),d0		; period / TRK_TICKDIV
	cmp.w	#$ffff,d0
	seq	TC_ONE(a0)
	bne.s	.lp
	moveq	#0,d0
.lp	mulu.w	TP_PERIOD(a1),d0
	divu.l	#TRK_TICKDIV,d0
	move.w	d0,TC_LOOPT(a0)
	moveq	#0,d0
	move.w	TS_LEN(a2),d0
	mulu.w	TP_PERIOD(a1),d0
	divu.l	#TRK_TICKDIV,d0
	cmp.l	#$ffff,d0
	bls.s	.e
	move.l	#$ffff,d0
.e	move.w	d0,TC_ENDT(a0)
	movem.l	(sp)+,d0-d2/a0-a2
	rts

; a5 = channel (given a note last tick), a2 = its registers, d7 = its number:
; start it
ch_start:
	movem.l	d0-d1/a0-a1,-(sp)
	move.l	TC_SMP(a5),a0
	move.l	TC_PRE(a5),a1
	move.l	TV_BANK(a4),d0
	add.l	TS_OFF(a0),d0
	move.l	d0,(a2)			; AUDxLC
	move.w	TS_LEN(a0),4(a2)
	move.w	TP_PERIOD(a1),6(a2)
	move.w	TV_TICK(a4),d0
	move.w	d0,TC_START(a5)
	add.w	TC_DUR(a5),d0
	move.w	d0,TC_T1(a5)
	clr.w	TC_REL(a5)
	clr.w	TC_FADED(a5)
	bsr	ch_volume
	move.w	#$8000,d0		; DMA on
	bset	d7,d0
	move.w	d0,DMACON(a6)
	move.b	#2,TC_STATE(a5)
	movem.l	(sp)+,d0-d1/a0-a1
	rts

; the first pass started: its loop, or silence after it
ch_loop:
	movem.l	d0/a0,-(sp)
	move.l	TC_SMP(a5),a0
	tst.b	TC_ONE(a5)
	bne.s	.one
	moveq	#0,d0
	move.w	TS_LOOP(a0),d0
	add.l	d0,d0
	add.l	TV_BANK(a4),d0
	add.l	TS_OFF(a0),d0
	move.l	d0,(a2)
	move.w	TS_LLEN(a0),4(a2)
	bra.s	.x
.one	lea	trk_silence(pc),a0
	move.l	a0,(a2)
	move.w	#1,4(a2)
.x	move.b	#3,TC_STATE(a5)
	movem.l	(sp)+,d0/a0
	rts

; a playing channel's fade this tick, then its volume
ch_fade:
	movem.l	d0-d3/a0-a1,-(sp)
	move.l	TC_SMP(a5),a0
	move.l	TC_PRE(a5),a1
	move.w	TV_TICK(a4),d1
	move.w	d1,d0
	sub.w	TC_T1(a5),d0
	bmi.s	.held
	moveq	#0,d0			; released: the release, by block
	move.b	TP_BLOCK(a1),d0
	move.w	TS_REL(a0,d0.w*2),d0
	bra.s	.add
.held	tst.b	TC_ONE(a5)		; held, in the loop: decay, then sustain
	bne.s	.none
	sub.w	TC_START(a5),d1
	cmp.w	TC_LOOPT(a5),d1
	blo.s	.none
	move.w	TC_FADED(a5),d0
	cmp.w	TS_TOTAL(a0),d0
	bhs.s	.sus
	move.w	TS_DR(a0),d0
	bsr	trk_eg
	add.w	d0,TC_FADED(a5)
	bvc.s	.add
	move.w	#$7fff,TC_FADED(a5)
	bra.s	.add
.sus	move.w	TS_SR(a0),d0
	bsr	trk_eg
.add	add.w	d0,TC_REL(a5)
	bvc.s	.none
	move.w	#$7fff,TC_REL(a5)
.none	tst.b	TC_ONE(a5)		; a one-shot played to its end: off
	beq.s	.v
	move.w	TV_TICK(a4),d1
	sub.w	TC_START(a5),d1
	cmp.w	TC_ENDT(a5),d1
	blo.s	.v
	clr.b	TC_STATE(a5)
	clr.w	8(a2)
	bra.s	.x
.v	bsr	ch_volume
.x	movem.l	(sp)+,d0-d3/a0-a1
	rts

; a5 = channel, a2 = its registers: AUDxVOL from its level and fades
ch_volume:
	movem.l	d0-d1/a0,-(sp)
	move.l	TC_SMP(a5),a0
	moveq	#0,d0
	move.b	TC_LVL(a5),d0
	moveq	#0,d1
	move.b	TS_ATT(a0),d1
	add.w	d1,d0
	move.w	TC_REL(a5),d1
	lsr.w	#8,d1
	add.w	d1,d0
	cmp.w	#128,d0
	bhs.s	.zero
	lea	att_vols(pc),a0
	move.b	(a0,d0.w),d0
	move.w	d0,8(a2)
	movem.l	(sp)+,d0-d1/a0
	rts
.zero	clr.w	8(a2)
	movem.l	(sp)+,d0-d1/a0
	rts

; d0.w = an envelope rate code (rate without key scaling << 8 | key
; scaling), a1 = the preset -> d0.w = its step this tick (1/256 TL steps)
trk_eg:
	movem.l	d1-d2,-(sp)
	moveq	#0,d1
	move.w	d0,d1
	lsr.w	#8,d1
	beq.s	.zero
	moveq	#3,d2
	and.w	d0,d2
	neg.w	d2
	addq.w	#3,d2
	moveq	#0,d0
	move.b	TP_KC(a1),d0
	lsr.w	d2,d0
	add.w	d0,d1
	cmp.w	#63,d1
	bls.s	.r
	moveq	#63,d1
.r	move.w	trk_eg_steps(pc,d1.w*2),d0
	movem.l	(sp)+,d1-d2
	rts
.zero	moveq	#0,d0
	movem.l	(sp)+,d1-d2
	rts
; per envelope rate: its step per tick (1/256 TL steps; tracker.py EG_STEPS)
trk_eg_steps:
	dc.w	0,1,1,1,1,1,2,2,2,3,3,4,4,5,6,7
	dc.w	8,10,12,15,17,21,25,29,33,41,50,58,66,83,99,116
	dc.w	133,166,199,232,265,332,398,464,531,663,796,929,1061,1326,1592,1857
	dc.w	2122,2653,3183,3714,4245,5306,6367,7428,8489,10612,12734,14856,16979,21223,25468,29712

;------------------------------------------------------------------------------
; a3 = a voice: its next note (VO_N*), or done
trk_read:
	movem.l	d0-d3/a0-a1,-(sp)
	move.l	VO_PTR(a3),a0
.cmd	move.b	(a0)+,d0
	moveq	#15,d1
	and.b	d0,d1
	beq.s	.note
	cmp.b	#1,d1
	bne.s	.c2
	move.b	(a0)+,VO_LVL(a3)	; level
	bra.s	.cmd
.c2	cmp.b	#2,d1
	bne.s	.c3
	move.l	TV_TUNE(a4),a1		; sync: time from the loop's start, no pairs
	move.w	TU_LOOP(a1),VO_T(a3)
	clr.w	VO_NC(a3)
	bra.s	.cmd
.c3	st	VO_DONE(a3)		; end
	bra	.x
.note	moveq	#0,d1			; preset
	move.b	(a0)+,d1
	cmp.b	#255,d1
	bne.s	.pr
	move.b	(a0)+,d1
	lsl.w	#8,d1
	move.b	(a0)+,d1
.pr	move.w	d1,VO_NPRE(a3)
	moveq	#0,d2
	move.b	d0,d2
	lsr.b	#6,d2			; the pair: 0-2 from the cache, 3 new
	cmp.b	#3,d2
	bne.s	.old
	bsr.s	.num			; new: gap << 16 | length, in front (the
	move.w	d1,d3			; cache keeps the last 3)
	swap	d3
	bsr.s	.num
	move.w	d1,d3
	move.w	VO_NC(a3),d2
	cmp.w	#3,d2
	blo.s	.grow
	moveq	#2,d2
	bra.s	.front
.grow	addq.w	#1,VO_NC(a3)
	bra.s	.front
.old	move.l	VO_CACHE(a3,d2.w*4),d3	; taken out, then in front
.front	tst.w	d2			; (the ones before it a place on)
	beq.s	.put
	move.l	VO_CACHE-4(a3,d2.w*4),VO_CACHE(a3,d2.w*4)
	subq.w	#1,d2
	bra.s	.front
.put	move.l	d3,VO_CACHE(a3)
	move.w	d3,VO_NDUR(a3)		; length
	swap	d3			; gap
	add.w	VO_T(a3),d3
	move.w	d3,VO_T(a3)
	move.w	d3,VO_NT0(a3)
	move.b	VO_LVL(a3),VO_NLVL(a3)
	btst	#5,d0
	sne	VO_NMINOR(a3)
	moveq	#127,d1			; priority: 127 - level (+8 a chord's top / bottom)
	moveq	#0,d2
	move.b	VO_LVL(a3),d2
	sub.w	d2,d1
	btst	#4,d0
	beq.s	.pri
	addq.w	#8,d1
.pri	move.w	d1,VO_NPRI(a3)
.x	move.l	a0,VO_PTR(a3)
	movem.l	(sp)+,d0-d3/a0-a1
	rts
; a number: < $80 a byte, else $80 | high, low -> d1
.num	moveq	#0,d1
	move.b	(a0)+,d1
	bpl.s	.n1
	and.b	#$7f,d1
	lsl.w	#8,d1
	move.b	(a0)+,d1
.n1	rts

;------------------------------------------------------------------------------
; d0.b = a sound command (port 0): a tune, a stop, or an effect
trk_command:
	movem.l	d0-d7/a0-a6,-(sp)
	lea	trk_vars(pc),a4
	lea	CUSTOM,a6
	and.w	#$ff,d0
	cmp.b	#$00,d0			; everything stops
	bne.s	.n0
	bsr	trk_stop
	move.w	sr,-(sp)
	ori.w	#$0700,sr
	bsr	trk_fx_command
	move.w	(sp)+,sr
	bra	.x
.n0	cmp.b	#$38,d0			; the music stops
	bne.s	.n38
	bsr	trk_stop
	bra	.x
.n38	cmp.b	#$20,d0			; a tune?
	blo	.fx
	cmp.b	#$40,d0
	bhs	.fx
	move.l	TV_BANK(a4),a0
	move.w	d0,d1
	sub.w	#$20,d1
	move.l	TB_TUNES(a0,d1.w*4),d1
	beq	.fx			; (none: an effect, e.g. the credit's)
	bsr	trk_stop
	tst.b	TV_ON(a4)
	beq	.x
	add.l	d1,a0			; the tune: its streams unpacked (the timer
	move.l	a0,a5			; leaves it alone meanwhile)
	lea	TU_SIZE(a5),a1
	move.l	a1,TV_PRE(a4)
	moveq	#0,d0
	move.w	TU_PRESETS(a5),d0
	mulu.w	#TP_SIZE,d0
	lea	(a1,d0.l),a0
	move.l	TV_BUF(a4),a1
	bsr	lz_unpack
	lea	TV_VOICES(a4),a3
	lea	TU_STREAMS(a5),a2
	moveq	#6-1,d7
.v	move.l	TV_BUF(a4),a0
	moveq	#0,d0
	move.w	(a2)+,d0
	add.l	a0,d0
	move.l	d0,VO_PTR(a3)
	moveq	#0,d0
	move.w	(a2)+,d0
	add.l	a0,d0
	move.l	d0,VO_LP(a3)
	clr.w	VO_T(a3)
	clr.w	VO_NC(a3)
	clr.b	VO_LVL(a3)
	sf	VO_DONE(a3)
	lea	VO_SIZE(a3),a3
	dbf	d7,.v
	move.w	sr,-(sp)		; (not a tick in between)
	ori.w	#$0700,sr
	move.l	a5,TV_TUNE(a4)		; (trk_read: the sync reads TU_LOOP)
	clr.w	TV_POS(a4)
	lea	TV_VOICES(a4),a3
	moveq	#6-1,d7
.r	bsr	trk_read
	lea	VO_SIZE(a3),a3
	dbf	d7,.r
	move.w	(sp)+,sr
	bra.s	.x
.fx	move.w	sr,-(sp)
	ori.w	#$0700,sr
	bsr	trk_fx_command
	move.w	(sp)+,sr
.x	movem.l	(sp)+,d0-d7/a0-a6
	rts

; the music stops: no tune, its channels silent
trk_stop:
	movem.l	d0/d7/a2/a5,-(sp)
	move.w	sr,-(sp)
	ori.w	#$0700,sr
	clr.l	TV_TUNE(a4)
	lea	TV_CHANS(a4),a5
	lea	CUSTOM+AUD0LC,a2
	moveq	#0,d7
.c	tst.b	TC_MODE(a5)
	bne.s	.n
	clr.b	TC_STATE(a5)
	clr.w	8(a2)
	moveq	#1,d0
	lsl.w	d7,d0
	move.w	d0,CUSTOM+DMACON
.n	lea	TC_SIZE(a5),a5
	lea	16(a2),a2
	addq.w	#1,d7
	cmp.w	#4,d7
	bne.s	.c
	move.w	(sp)+,sr
	movem.l	(sp)+,d0/d7/a2/a5
	rts

; d0.b: tunes play (not 0) or not (and the one playing stops)
trk_music:
	movem.l	a4,-(sp)
	lea	trk_vars(pc),a4
	move.b	d0,TV_ON(a4)
	bne.s	.x
	bsr	trk_stop
.x	movem.l	(sp)+,a4
	rts

;------------------------------------------------------------------------------
; the effects (fx_play.s's samples and records), each on a channel of its
; own while it plays: d0.b = a command (interrupts masked)
trk_fx_command:
	movem.l	d0-d3/a0-a1/a4-a5,-(sp)
	lea	fx_vars(pc),a4
	and.w	#$ff,d0
	cmp.b	#$00,d0			; stop every effect
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
	add.w	d1,a0
	tst.l	(a0)
	beq	.x			; (no sample)
	bsr	trk_fx_channel		; -> a5, d3 = channel
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
	bsr	trk_fx_on		; (the channel switched to it, if not yet)
	bra	.x
.all	moveq	#4-1,d1
	lea	FV_CHAN(a4),a5
.al	clr.l	FC_PTR(a5)
	lea	FC_SIZE(a5),a5
	dbf	d1,.al
.x	movem.l	(sp)+,d0-d3/a0-a1/a4-a5
	rts

; d0 = effect -> a5 = its channel's record, d3 = the channel: where it plays
; already; else a channel neither an effect's nor sounding music; else the
; music channel with the lowest priority; else the effect that started
; longest ago (one-shots before loops)
trk_fx_channel:
	movem.l	d1-d2/d4/a0/a2,-(sp)
	lea	trk_vars+TV_CHANS(pc),a2
	lea	FV_CHAN(a4),a5
	moveq	#0,d3
.same	tst.l	FC_PTR(a5)
	beq.s	.ns
	cmp.b	FC_CMD(a5),d0
	beq	.got
.ns	lea	FC_SIZE(a5),a5
	addq.w	#1,d3
	cmp.w	#4,d3
	bne.s	.same
	lea	FV_CHAN(a4),a5		; free of both
	moveq	#0,d3
	move.l	a2,a0
.free	tst.b	TC_MODE(a0)
	bne.s	.nf
	movem.l	a0/a4,-(sp)
	lea	trk_vars(pc),a4
	bsr	ch_busy
	movem.l	(sp)+,a0/a4
	beq	.got
.nf	lea	FC_SIZE(a5),a5
	lea	TC_SIZE(a0),a0
	addq.w	#1,d3
	cmp.w	#4,d3
	bne.s	.free
	moveq	#-1,d4			; music: the lowest priority
	move.w	#$7fff,d2
	moveq	#0,d3
	move.l	a2,a0
.mus	tst.b	TC_MODE(a0)
	bne.s	.nm
	cmp.w	TC_PRI(a0),d2
	ble.s	.nm
	move.w	TC_PRI(a0),d2
	move.w	d3,d4
.nm	lea	TC_SIZE(a0),a0
	addq.w	#1,d3
	cmp.w	#4,d3
	bne.s	.mus
	move.w	d4,d3
	bpl.s	.idx
	lea	FV_CHAN(a4),a0		; all effects: the oldest (a loop counts as
	moveq	#-1,d2			; newer than any one-shot)
	moveq	#0,d1
	moveq	#0,d3
.old	move.l	FC_AGE(a0),d4
	tst.l	FC_LOOP(a0)
	beq.s	.os
	bset	#31,d4
.os	cmp.l	d2,d4
	bhs.s	.on
	move.l	d4,d2
	move.w	d1,d3
.on	lea	FC_SIZE(a0),a0
	addq.w	#1,d1
	cmp.w	#4,d1
	bne.s	.old
.idx	lea	FV_CHAN(a4),a5
	move.w	d3,d1
	mulu.w	#FC_SIZE,d1
	add.l	d1,a5
.got	movem.l	(sp)+,d1-d2/d4/a0/a2
	rts

; d3 = channel, a5 = its effect's record: the channel plays effects (its
; music note stops; the first half filled, DMA started: its interrupt from
; now on fills the halves)
trk_fx_on:
	movem.l	d0-d7/a0-a6,-(sp)
	lea	trk_vars(pc),a4
	lea	TV_CHANS(a4),a0
	move.w	d3,d0
	mulu.w	#TC_SIZE,d0
	add.l	d0,a0
	cmp.b	#2,TC_MODE(a0)
	beq	.x			; (already)
	move.b	#2,TC_MODE(a0)
	clr.b	TC_STATE(a0)
	lea	CUSTOM,a6
	moveq	#1,d0
	lsl.w	d3,d0
	move.w	d0,DMACON(a6)		; DMA off
	move.w	d3,d0
	lsl.w	#4,d0
	lea	AUD0LC(a6,d0.w),a1
	move.l	TV_FXBUF(a4),a3		; its halves: 2 x FX_CHUNK
	move.w	d3,d0
	mulu.w	#2*FX_CHUNK,d0
	add.l	d0,a3
	move.l	a3,(a1)
	move.w	#FX_CHUNK/2,4(a1)
	move.w	#FX_PERIOD,6(a1)
	lea	trk_fxhalf(pc),a2	; (half 0 plays first: filled now)
	clr.b	(a2,d3.w)
	move.l	TV_FXBANK(a4),a2
	lea	FX_COUNT*FX_REC(a2),a2
	movem.l	d3/a1,-(sp)
	bsr	fx_fill
	movem.l	(sp)+,d3/a1
	move.w	d5,8(a1)
	lea	trk_fxhalf(pc),a2	; (its volume, as the interrupt sets it when
	move.b	d5,8(a2,d3.w)		; the half starts)
	tst.b	d5
	seq	4(a2,d3.w)
	move.w	#$8000,d0
	bset	d3,d0
	move.w	d0,DMACON(a6)
	move.w	#$0080,d0		; its interrupt (the first: as it starts)
	lsl.w	d3,d0
	or.w	#$8000,d0
	move.w	d0,INTENA(a6)
.x	movem.l	(sp)+,d0-d7/a0-a6
	rts

; level 4: a channel playing effects starts a half - the other one is filled
; (the next to play); an effect over - its silent half started - gives the
; channel back to the music
trk_aud:
	movem.l	d0-d7/a0-a6,-(sp)
	lea	CUSTOM,a6
	move.w	INTREQR(a6),d6
	and.w	INTENAR(a6),d6
	and.w	#$0780,d6
	move.w	d6,INTREQ(a6)
	move.w	d6,INTREQ(a6)
	lsr.w	#7,d6			; channels
	lea	trk_vars(pc),a4
	lea	fx_vars(pc),a0
	moveq	#0,d3			; channel
.c	btst	d3,d6
	beq	.n
	lea	TV_CHANS(a4),a1
	move.w	d3,d0
	mulu.w	#TC_SIZE,d0
	cmp.b	#2,TC_MODE(a1,d0.w)
	bne	.n
	lea	FV_CHAN(a0),a5
	move.w	d3,d0
	mulu.w	#FC_SIZE,d0
	add.l	d0,a5
	lea	trk_fxhalf(pc),a2
	move.w	d3,d0
	lsl.w	#4,d0
	lea	AUD0LC(a6,d0.w),a1
	tst.l	FC_PTR(a5)		; over, and its last half (silent) starting:
	bne.s	.play			; the channel goes back to the music
	tst.b	4(a2,d3.w)
	beq.s	.play
	moveq	#1,d0			; DMA off, its interrupt off
	lsl.w	d3,d0
	move.w	d0,DMACON(a6)
	lsl.w	#7,d0
	move.w	d0,INTENA(a6)
	clr.w	8(a1)
	lea	TV_CHANS(a4),a3
	move.w	d3,d0
	mulu.w	#TC_SIZE,d0
	clr.b	TC_MODE(a3,d0.w)
	clr.b	TC_STATE(a3,d0.w)
	bra.s	.n
.play	moveq	#0,d0			; the half starting: its volume
	move.b	8(a2,d3.w),d0
	move.w	d0,8(a1)
	move.b	(a2,d3.w),d0		; the other half: next, filled now
	eori.b	#1,d0
	move.b	d0,(a2,d3.w)
	move.l	TV_FXBUF(a4),a3
	move.w	d3,d1
	mulu.w	#2*FX_CHUNK,d1
	add.l	d1,a3
	tst.b	d0
	beq.s	.h0
	lea	FX_CHUNK(a3),a3
.h0	move.l	a3,(a1)
	move.l	FV_BANK(a0),a2
	lea	FX_COUNT*FX_REC(a2),a2
	movem.l	d3/d6/a0-a1/a4,-(sp)
	bsr	fx_fill
	movem.l	(sp)+,d3/d6/a0-a1/a4
	lea	trk_fxhalf(pc),a2
	move.b	d5,8(a2,d3.w)		; its volume, for when it starts
	tst.b	d5			; (silent: the effect is over)
	seq	4(a2,d3.w)
.n	addq.w	#1,d3
	cmp.w	#4,d3
	bne	.c
	movem.l	(sp)+,d0-d7/a0-a6
	rte

; per channel: the half to fill next (0 / 1), +4: the last filled was
; silent, +8: the volume of the half filled last
trk_fxhalf:	ds.b	12
		even
trk_silence:	dc.l	0		; (a one-shot's loop: silence)
		cnop	0,4
trk_vars:	ds.b	TV_SIZE
trk_notes:	ds.b	6*VO_SIZE	; (the notes due this tick: copies)
		even
