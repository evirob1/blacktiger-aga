; Black Tiger AGA - the sound player: the YM2203s' registers (src/sound.s)
; as 12 voices mixed into Paula's 4 channels.
;
; The 6 FM channels play samples from the instrument bank (tools/sound/bank.py,
; one per patch: found by a hash of the patch's registers at key on); the 6
; SSG channels a square wave or noise. 3 voices are mixed into each channel
; (FM #1, FM #2, SSG #1, SSG #2), CHUNK samples at a time at Paula period
; PERIOD, double-buffered: channel 0's interrupt (one per chunk) runs the
; sound program for the chunk's time, updates the voices and mixes the next
; chunk.
;
;   play_init    a0 = the output buffers (chip RAM, PLAY_BUFSIZE): tables,
;                then audio DMA and its interrupt (level 4, via the VBR) running
;   play_irq     the level 4 interrupt handler
;
; The instrument bank (BANK_PATCHES records, then the samples) follows the
; sound program's ROM (at snd_a6); the player's tables and variables are in
; the window of the sound CPU's memory it leaves alone (src/sound.s: it uses
; $C000-$C800 and $E000). The includer defines CUSTOM and BANK_PATCHES.

AUD0LC		equ	$0a0		; (+$10 a channel: LC, LEN +4, PER +6, VOL +8)

SQ_CYCLES	equ	128		; the square wave's loop: many cycles (the mixer
					; works in stretches between ends of samples)
PERIOD		equ	384		; 9237 Hz (PAL): tools/sound/model.py
CHUNK		equ	96		; samples per chunk: 10.4 ms
PLAY_BUFSIZE	equ	4*2*CHUNK	; 4 channels, 2 halves
; YM timer units (72 YM clocks) per chunk, << 8: CHUNK * PERIOD / 3546895 * 3579545 / 72 * 256
UNITS_CHUNK	equ	132279
FM_VOICES	equ	6
PLAY_VOLS	equ	31*256		; volumes 2, 4 .. 62 (0: not mixed; 64: as 62)
NOISE_LEN	equ	2048		; random bytes: the SSG's noise
VOICES		equ	12

; a bank patch (bank_patches, tools/sound/bank.py)
	rsreset
BP_HASH		rs.w	1
BP_ATT		rs.w	1		; its loudness: attenuation in TL steps (0.75 dB)
BP_K		rs.w	1		; pitch: step (16.16) = (fnum << block) * K >> 8
BP_REL		rs.w	1		; release: 1/16 TL steps per chunk
BP_FADE1	rs.w	1		; held, in the loop: the decay's rest (rate,
BP_TOTAL1	rs.w	1		; total), then
BP_FADE2	rs.w	1		; the sustain rate
		rs.w	1
BP_START	rs.l	1		; offset in bank_samples
BP_LEN		rs.l	1
BP_LOOP		rs.l	1		; offset of the loop, or -1 (one-shot)
BP_SIZE		rs.b	0

; a voice
	rsreset
V_BASE		rs.l	1		; the sample (or 0: silent)
V_POS		rs.l	1		; 16.16
V_STEP		rs.l	1		; 16.16
V_END		rs.l	1		; length << 16
V_LOOP		rs.l	1		; loop length << 16 (0: one-shot)
V_VOL		rs.l	1		; volume 1-64 (0: silent)
V_ROW		rs.l	1		; its play_vols row, as the channel is scaled
V_PATCH		rs.l	1		; bank patch (FM)
V_REL		rs.w	1		; extra attenuation (1/16 TL steps): release, fade
V_FADED		rs.w	1		; (how much of the decay's rest is done)
V_SIZE		rs.b	0

	rsreset
PV_VOICES	rs.b	V_SIZE*VOICES
PV_BUF		rs.l	1		; output buffers
PV_HALF		rs.w	1		; the half being filled next (0 / 1)
PV_UNITS	rs.l	1		; YM timer time not yet run (<< 8)
PV_VOLS		rs.l	1		; the volume table
PV_NOISE	rs.l	1
PV_PATCHES	rs.l	1		; the bank
PV_SAMPLES	rs.l	1
PV_ATTVOL	rs.b	128		; attenuation (TL steps) -> volume 0-64
PV_NEXTVOL	rs.b	4		; per channel: Paula volume for the half mixed
PV_SIZE		rs.b	0

; in the sound CPU's memory window (offsets from snd_a6, its $8000)
SW_NOISE	equ	$c804-$10000		; ($C804)
SW_VARS		equ	SW_NOISE+NOISE_LEN
SW_VOLS		equ	$e004-$10000		; ($E004)
	ifgt	SW_VARS+PV_SIZE-($e000-$10000)
	fail	"the player's variables reach the YM status ($E000)"
	endif

; carriers of each algorithm, as a mask of the operators in register order
; (slots 1, 3, 2, 4)
carrier_masks:	dc.b	%1000,%1000,%1000,%1000,%1100,%1110,%1110,%1111
; SSG volume 0-15 -> 0-64 (the AY curve, at the SSG's level against FM)
ssg_vols:	dc.b	0,1,1,1,2,3,4,7,9,14,18,23,29,35,43,51
	even

play_init:
	movem.l	d0-d7/a0-a6,-(sp)
	move.l	snd_a6(pc),a1
	lea	SW_VARS(a1),a4
	move.l	a0,PV_BUF(a4)
	lea	SW_VOLS(a1),a2
	move.l	a2,PV_VOLS(a4)
	lea	SW_NOISE(a1),a2
	move.l	a2,PV_NOISE(a4)
	lea	$8000(a1),a2		; the bank: after the ROM
	move.l	a2,PV_PATCHES(a4)
	lea	BANK_PATCHES*BP_SIZE(a2),a2
	move.l	a2,PV_SAMPLES(a4)
	move.w	#1,PV_HALF(a4)		; (half 0 plays first)
	move.w	#PLAY_BUFSIZE-1,d0
.cb	clr.b	(a0)+
	dbf	d0,.cb
	move.l	PV_NOISE(a4),a0	; noise: random bytes (+-127)
	move.l	#$1234567,d1
	move.w	#NOISE_LEN-1,d0
.nz	move.l	d1,d2			; (xorshift)
	lsl.l	#7,d2
	eor.l	d2,d1
	move.l	d1,d2
	lsr.l	#5,d2
	eor.l	d2,d1
	move.b	d1,(a0)+
	dbf	d0,.nz
	move.l	PV_VOLS(a4),a0	; row r: b -> b * v / 64 / 3 (3 voices a channel),
	moveq	#2,d1			; v = 2r + 2
.row	moveq	#0,d2			; b
.col	move.b	d2,d3
	ext.w	d3
	muls.w	d1,d3
	bmi.s	.neg			; (rounded)
	add.l	#96,d3
	bra.s	.div
.neg	sub.l	#96,d3
.div	divs.w	#192,d3
	move.b	d3,(a0)+
	addq.w	#1,d2
	cmp.w	#256,d2
	bne.s	.col
	addq.w	#2,d1
	cmp.w	#64,d1
	bne.s	.row
	lea	PV_ATTVOL(a4),a0	; 64 * 10^(-0.75 * att / 20), att 0-127
	lea	att_vols(pc),a1
	moveq	#128-1,d0
.av	move.b	(a1)+,(a0)+
	dbf	d0,.av
	lea	CUSTOM,a6
	move.w	#$000f,DMACON(a6)	; audio off while set up
	move.l	PV_BUF(a4),a0
	lea	AUD0LC(a6),a1
	moveq	#4-1,d0
.ch	move.l	a0,(a1)			; channel n: blocks of a chunk, half 0 first
	move.w	#CHUNK/2,4(a1)
	move.w	#PERIOD,6(a1)
	move.w	#64,8(a1)
	lea	16(a1),a1
	lea	2*CHUNK(a0),a0
	dbf	d0,.ch
	movec	vbr,a0
	lea	play_irq(pc),a1
	move.l	a1,$70(a0)
	move.w	#$0780,INTREQ(a6)
	move.w	#$c080,INTENA(a6)	; channel 0's block interrupt
	move.w	#$800f,DMACON(a6)
	movem.l	(sp)+,d0-d7/a0-a6
	rts

; Channel 0's interrupt comes as it starts a block (a chunk, from AUDxLC,
; now latched): point every channel at the other half, which plays next (and
; has just finished playing), and fill it.
play_irq:
	movem.l	d0-d7/a0-a6,-(sp)
	lea	CUSTOM,a6
	move.w	#$0080,INTREQ(a6)
	move.w	#$0080,INTREQ(a6)
	move.l	snd_a6(pc),a4
	lea	SW_VARS(a4),a4
	moveq	#0,d0			; the half mixed last starts now: its
	move.b	PV_NEXTVOL(a4),d0	; channels' volumes (play_mix)
	move.w	d0,AUD0LC+8(a6)
	move.b	PV_NEXTVOL+1(a4),d0
	move.w	d0,AUD0LC+$18(a6)
	move.b	PV_NEXTVOL+2(a4),d0
	move.w	d0,AUD0LC+$28(a6)
	move.b	PV_NEXTVOL+3(a4),d0
	move.w	d0,AUD0LC+$38(a6)
	move.w	PV_HALF(a4),d0
	move.l	PV_BUF(a4),a0
	mulu.w	#CHUNK,d0
	add.l	d0,a0
	lea	AUD0LC(a6),a1
	moveq	#4-1,d1
.lc	move.l	a0,(a1)
	lea	16(a1),a1
	lea	2*CHUNK(a0),a0
	dbf	d1,.lc
	move.l	PV_UNITS(a4),d0		; the sound program, for a chunk's time
	add.l	#UNITS_CHUNK,d0
	move.l	d0,d1
	and.l	#$ff,d1
	move.l	d1,PV_UNITS(a4)
	lsr.l	#8,d0
	bsr	snd_timer
	bsr	play_voices
	bsr	play_mix
	eori.w	#1,PV_HALF(a4)
	movem.l	(sp)+,d0-d7/a0-a6
	rte

;------------------------------------------------------------------------------
; the voices from the registers
play_voices:
	lea	ym_regs(pc),a3
	lea	PV_VOICES(a4),a5
	moveq	#0,d7			; FM voice 0-5
.fm	moveq	#0,d6
	move.w	d7,d6
	divu.w	#3,d6			; chip in the low word, channel in the high
	move.l	d6,d5
	swap	d5			; d5 = channel
	lsl.w	#8,d6
	lea	(a3,d6.w),a2		; that chip's registers
	lea	ym_keyon(pc),a0
	bclr	#7,(a0,d7.w)		; keyed on since last time: a new note
	beq.s	.nk
	bsr	fm_start
.nk	tst.l	V_BASE(a5)
	beq.s	.next
	bsr	fm_update
.next	lea	V_SIZE(a5),a5
	addq.w	#1,d7
	cmp.w	#FM_VOICES,d7
	bne.s	.fm
	moveq	#0,d7			; SSG: chip 0, 1
.sc	move.w	d7,d6
	lsl.w	#8,d6
	lea	(a3,d6.w),a2
	moveq	#0,d5			; channel
.sv	bsr	ssg_update
	lea	V_SIZE(a5),a5
	addq.w	#1,d5
	cmp.w	#3,d5
	bne.s	.sv
	addq.w	#1,d7
	cmp.w	#2,d7
	bne.s	.sc
	rts

; a2 = the chip's registers, d5 = channel, a5 = voice: a new note
fm_start:
	movem.l	d5-d7,-(sp)
	bsr	fm_hash			; -> d0
	move.l	PV_PATCHES(a4),a0	; binary search by hash
	moveq	#0,d1			; lo
	move.w	#BANK_PATCHES,d2	; hi
.bs	cmp.w	d2,d1
	bhs.s	.none
	move.w	d1,d3
	add.w	d2,d3
	lsr.w	#1,d3
	move.w	d3,d4
	mulu.w	#BP_SIZE,d4
	cmp.w	BP_HASH(a0,d4.l),d0
	beq.s	.hit
	blo.s	.lo
	move.w	d3,d1
	addq.w	#1,d1
	bra.s	.bs
.lo	move.w	d3,d2
	bra.s	.bs
.none	clr.l	V_BASE(a5)		; (a patch the bank hasn't got: silent)
	bra.s	.x
.hit	lea	(a0,d4.l),a0
	move.l	a0,V_PATCH(a5)
	move.l	PV_SAMPLES(a4),a1
	add.l	BP_START(a0),a1
	move.l	a1,V_BASE(a5)
	clr.l	V_POS(a5)
	move.l	BP_LEN(a0),d0
	swap	d0
	clr.w	d0
	move.l	d0,V_END(a5)
	move.l	BP_LOOP(a0),d1
	bmi.s	.os
	move.l	BP_START(a0),d2		; loop length = start + length - loop
	add.l	BP_LEN(a0),d2
	sub.l	d1,d2
	swap	d2
	clr.w	d2
	move.l	d2,V_LOOP(a5)
	bra.s	.r
.os	clr.l	V_LOOP(a5)
.r	clr.w	V_REL(a5)
	clr.w	V_FADED(a5)
.x	movem.l	(sp)+,d5-d7
	rts

; a2 = registers, d5 = channel -> d0.w = the instrument's hash
; (tools/sound/bank.py, patch_hash): rotate-and-xor over $30-$90 but the
; levels (register order) and FB/ALG
fm_hash:
	movem.l	d1-d4/a0-a1,-(sp)
	moveq	#0,d0
	lea	(a2,d5.w),a0
	moveq	#6-1,d1			; $30, $50, $60, $70, $80, $90
	moveq	#$30,d3
.base	moveq	#4-1,d2
	lea	(a0,d3.w),a1
.op	rol.w	#3,d0
	moveq	#0,d4
	move.b	(a1),d4
	eor.w	d4,d0
	addq.l	#4,a1
	dbf	d2,.op
	add.w	#$10,d3
	cmp.w	#$40,d3
	bne.s	.nt
	moveq	#$50,d3			; (not the levels)
.nt	dbf	d1,.base
	rol.w	#3,d0
	moveq	#$3f,d4
	and.b	$b0(a0),d4
	eor.w	d4,d0
	movem.l	(sp)+,d1-d4/a0-a1
	rts

; a2 = registers, d5 = channel, a5 = a playing FM voice: pitch, loudness,
; release and fade for this chunk
fm_update:
	move.l	V_PATCH(a5),a0
	lea	ym_keyon(pc),a1
	moveq	#$0f,d0			; keyed (any slot on)?
	and.b	(a1,d7.w),d0
	bne.s	.held
	move.w	BP_REL(a0),d0		; released
	add.w	d0,V_REL(a5)
	bra.s	.att
.held	tst.l	V_LOOP(a5)		; held, in the loop: the fade
	beq.s	.att
	move.l	V_POS(a5),d0
	move.l	V_END(a5),d1
	sub.l	V_LOOP(a5),d1
	cmp.l	d1,d0
	blo.s	.att
	move.w	V_FADED(a5),d0
	cmp.w	BP_TOTAL1(a0),d0
	bhs.s	.f2
	move.w	BP_FADE1(a0),d0
	add.w	d0,V_FADED(a5)
	bra.s	.fa
.f2	move.w	BP_FADE2(a0),d0
.fa	add.w	d0,V_REL(a5)
.att	moveq	#7,d1			; loudness: the carriers' level (the lowest
	and.b	$b0(a2,d5.w),d1		; attenuation)
	move.b	carrier_masks(pc,d1.w),d1
	lea	$40(a2,d5.w),a1
	moveq	#$7f,d2
	moveq	#0,d3
.c	btst	d3,d1
	beq.s	.nc
	moveq	#$7f,d4
	and.b	(a1),d4
	cmp.w	d4,d2
	bls.s	.nc
	move.w	d4,d2
.nc	addq.l	#4,a1
	addq.w	#1,d3
	cmp.w	#4,d3
	bne.s	.c
	add.w	BP_ATT(a0),d2		; + the patch's own, + release / fade
	move.w	V_REL(a5),d3
	lsr.w	#4,d3
	add.w	d3,d2
	cmp.w	#127,d2
	bls.s	.v
	clr.l	V_BASE(a5)		; gone
	rts
.v	moveq	#0,d3
	move.b	PV_ATTVOL(a4,d2.w),d3
	bne.s	.vv
	clr.l	V_VOL(a5)		; (silent for now: not mixed)
	bra.s	.pitch
.vv	move.l	d3,V_VOL(a5)
.pitch	moveq	#0,d0			; pitch: (fnum << block) * K >> 8
	move.b	$a4(a2,d5.w),d0
	moveq	#7,d1
	and.w	d0,d1
	lsl.w	#8,d1
	move.b	$a0(a2,d5.w),d1		; fnum
	lsr.b	#3,d0
	and.w	#7,d0			; block
	and.l	#$ffff,d1
	lsl.l	d0,d1
	moveq	#0,d0
	move.w	BP_K(a0),d0
	mulu.l	d0,d1
	lsr.l	#8,d1
	move.l	d1,V_STEP(a5)
	rts

; a2 = the chip's registers, d5 = channel, a5 = voice: tone or noise
ssg_update:
	moveq	#$0f,d0
	and.b	8(a2,d5.w),d0		; volume
	beq	.off
	move.b	7(a2),d1		; mixer: bits 0-2 tone off, 3-5 noise off
	btst	d5,d1
	seq	d2			; tone on
	addq.w	#3,d5
	btst	d5,d1
	seq	d3			; noise on
	subq.w	#3,d5
	tst.b	d3
	bne.s	.noise
	tst.b	d2
	beq	.off
	lea	square(pc),a0		; tone: period (12 bits)
	moveq	#0,d1
	move.b	1(a2,d5.w*2),d1
	and.w	#$0f,d1
	lsl.w	#8,d1
	move.b	(a2,d5.w*2),d1
	move.l	#SQ_K,d2		; step = SQ_K / period
	move.l	#2*SQ_CYCLES<<16,d4
	bra.s	.set
.noise	move.l	PV_NOISE(a4),a0
	moveq	#$1f,d1
	and.b	6(a2),d1
	move.l	#NOISE_K,d2
	move.l	#NOISE_LEN<<16,d4
.set	tst.w	d1
	bne.s	.p
	moveq	#1,d1
.p	divu.l	d1,d2
	cmp.l	V_BASE(a5),a0		; (a change of source: from the start)
	beq.s	.same
	move.l	a0,V_BASE(a5)
	clr.l	V_POS(a5)
.same	move.l	d2,V_STEP(a5)
	move.l	d4,V_END(a5)
	move.l	d4,V_LOOP(a5)
	moveq	#0,d1
	move.b	ssg_vols(pc,d0.w),d1
	beq	.off
	move.l	d1,V_VOL(a5)
	rts
.off	clr.l	V_BASE(a5)
	rts

; SSG frequency = 3579545 / 2 / 16 / period (tools/sound/model.py, checked
; against MAME); step (16.16) = frequency * length of the source / rate
SQ_K		equ	1587343		; square: 2 bytes a cycle: 3579545 * 2 * 65536 / (32 * 9237)
NOISE_K		equ	793671		; noise: a byte a step: 3579545 * 65536 / (32 * 9237)

; d3.w = volume 1-64 -> its row in play_vols (volumes 2-62)
vol_row:
	cmp.w	#62,d3
	bls.s	.r
	moveq	#62,d3
.r	lsr.w	#1,d3
	subq.w	#1,d3
	bpl.s	.x
	moveq	#0,d3
.x	rts

;------------------------------------------------------------------------------
; mix the voices into the half being filled: 3 per channel
play_mix:
	move.l	a4,-(sp)
	move.l	PV_BUF(a4),a3
	move.w	PV_HALF(a4),d0
	mulu.w	#CHUNK,d0
	add.l	d0,a3			; channel 0's half
	lea	PV_VOICES(a4),a5
	moveq	#4-1,d7			; channels
.ch	moveq	#0,d6			; the channel's loudest voice: Paula's
	move.l	a5,a0			; volume for it (as the half starts), the
	moveq	#3-1,d5			; voices scaled to it (the 8 bits used to
.m	tst.l	V_BASE(a0)		; the full)
	beq.s	.mn
	move.l	V_VOL(a0),d0
	cmp.w	d6,d0
	bls.s	.mn
	move.w	d0,d6
.mn	lea	V_SIZE(a0),a0
	dbf	d5,.m
	moveq	#3,d0
	sub.w	d7,d0
	move.b	d6,PV_NEXTVOL(a4,d0.w)
	beq.s	.mix
	move.l	a5,a0
	moveq	#3-1,d5
.r	move.l	V_VOL(a0),d3
	beq.s	.rn
	lsl.w	#6,d3			; v * 64 / loudest
	divu.w	d6,d3
	bsr	vol_row
	and.l	#$ffff,d3
	lsl.l	#8,d3
	add.l	PV_VOLS(a4),d3
	move.l	d3,V_ROW(a0)
.rn	lea	V_SIZE(a0),a0
	dbf	d5,.r
.mix	movem.l	d7/a3/a5,-(sp)
	bsr	mix_channel
	movem.l	(sp)+,d7/a3/a5
	lea	3*V_SIZE(a5),a5
	lea	2*CHUNK(a3),a3
	dbf	d7,.ch
	move.l	(sp)+,a4
	rts

; a5 = a channel's three voices, a3 = its half of the output: CHUNK samples,
; the voices playing summed in a register (one write per sample), in stretches
; none of them gets to the end of its sample in
MF_STEP		equ	0			; the voices' steps, as positions are kept
MF_LIST		equ	12			; the voices playing
MF_A5		equ	24
MF_SIZE		equ	28
mix_channel:
	lea	-MF_SIZE(sp),sp
	move.l	a5,MF_A5(sp)
	move.w	#CHUNK,d7		; samples still to do
.seg	move.l	MF_A5(sp),a4		; the voices playing (looped or stopped at
	moveq	#0,d5			; the end of their samples), and d5: the
	move.w	d7,d5			; samples before one of them gets there
	moveq	#0,d6
	moveq	#3-1,d4
.g	tst.l	V_BASE(a4)
	beq.s	.gn
	tst.l	V_VOL(a4)
	beq.s	.gn
	move.l	V_POS(a4),d1
.w	move.l	V_END(a4),d0
	sub.l	d1,d0
	bhi.s	.in
	move.l	V_LOOP(a4),d0
	beq.s	.stop
	sub.l	d0,d1
	move.l	d1,V_POS(a4)
	bra.s	.w
.stop	clr.l	V_BASE(a4)
	bra.s	.gn
.in	move.l	V_STEP(a4),d1
	beq.s	.k
	add.l	d1,d0			; (rounded up)
	subq.l	#1,d0
	divu.l	d1,d0
	cmp.l	d5,d0
	bhs.s	.k
	move.w	d0,d5
.k	move.l	a4,MF_LIST(sp,d6.w*4)
	addq.w	#1,d6
.gn	lea	V_SIZE(a4),a4
	dbf	d4,.g
	sub.w	d5,d7
	subq.w	#1,d5			; (dbf)
	subq.w	#1,d6
	bmi.s	.zero
	beq.s	.one
	subq.w	#1,d6
	beq	.two
	bra	.three
.zero	addq.w	#1,d5			; silent: bytes to a long boundary, longs,
.zb	move.w	a3,d0			; then the rest
	and.w	#3,d0
	beq.s	.zl
	clr.b	(a3)+
	subq.w	#1,d5
	bne.s	.zb
	bra.s	.next
.zl	move.w	d5,d0
	lsr.w	#2,d0
	beq.s	.zr
	subq.w	#1,d0
.zll	clr.l	(a3)+
	dbf	d0,.zll
.zr	and.w	#3,d5
	beq.s	.next
	subq.w	#1,d5
.zrb	clr.b	(a3)+
	dbf	d5,.zrb
.next	tst.w	d7
	bne	.seg
	lea	MF_SIZE(sp),sp
	rts

; voice n's sample in an, its volume row in vn, position in pn: 16.16 kept
; swapped (integer part in the low word), stepped with the carry by addx. The
; steps of voices after the first are written into the loop's add.l #imm
; (immediates come from the instruction cache: no memory access)
MIX_IN	macro	; n, an, vn, pn
	move.l	MF_LIST+4*\1(sp),\3
	move.l	V_BASE(\3),\2
	move.l	V_POS(\3),\4
	swap	\4
	move.l	V_ROW(\3),\3
	endm
MIX_STEP macro	; n, where (its add.l #imm), or a register
	move.l	MF_LIST+4*\1(sp),a6
	move.l	V_STEP(a6),d3
	swap	d3
	ifc	"\2","d2"
	move.l	d3,d2
	else
	lea	\2+2(pc),a6
	move.l	d3,(a6)
	endc
	endm
MIX_OUT	macro	; n, pn
	move.l	MF_LIST+4*\1(sp),a6
	swap	\2
	move.l	\2,V_POS(a6)
	endm
MIX_ADD	macro	; op (move/add), an, vn, pn, step
	move.b	(\2,\4.w),d4
	\1.b	(\3,d4.w),d3
	add.l	\5,\4
	addx.w	d6,\4
	endm
CACHE_CLEAR macro			; (the instruction cache: the steps written)
	moveq	#9,d3			; (enable, clear)
	movec	d3,cacr
	endm

.one	MIX_IN	0,a0,a1,d0
	move.l	MF_LIST(sp),a6
	move.l	V_STEP(a6),d1
	swap	d1
	moveq	#0,d4
	moveq	#0,d6
.l1	move.b	(a0,d0.w),d4
	move.b	(a1,d4.w),(a3)+
	add.l	d1,d0
	addx.w	d6,d0
	dbf	d5,.l1
	MIX_OUT	0,d0
	bra	.next
.two	MIX_STEP 0,d2
	MIX_STEP 1,.s21
	CACHE_CLEAR
	MIX_IN	0,a0,a1,d0
	MIX_IN	1,a2,a4,d1
	moveq	#0,d4
	moveq	#0,d6
.l2	MIX_ADD	move,a0,a1,d0,d2
	move.b	(a2,d1.w),d4
	add.b	(a4,d4.w),d3
.s21	add.l	#$12345678,d1
	addx.w	d6,d1
	move.b	d3,(a3)+
	dbf	d5,.l2
	MIX_OUT	0,d0
	MIX_OUT	1,d1
	bra	.next
.three	MIX_STEP 0,.s30
	MIX_STEP 1,.s31
	MIX_STEP 2,.s32
	CACHE_CLEAR
	MIX_IN	0,a0,a1,d0
	MIX_IN	1,a2,a4,d1
	MIX_IN	2,a5,a6,d2
	moveq	#0,d4
	moveq	#0,d6
.l3	move.b	(a0,d0.w),d4
	move.b	(a1,d4.w),d3
.s30	add.l	#$12345678,d0
	addx.w	d6,d0
	move.b	(a2,d1.w),d4
	add.b	(a4,d4.w),d3
.s31	add.l	#$12345678,d1
	addx.w	d6,d1
	move.b	(a5,d2.w),d4
	add.b	(a6,d4.w),d3
.s32	add.l	#$12345678,d2
	addx.w	d6,d2
	move.b	d3,(a3)+
	dbf	d5,.l3
	MIX_OUT	0,d0
	MIX_OUT	1,d1
	MIX_OUT	2,d2
	bra	.next

; attenuation (TL steps of 0.75 dB) -> volume 0-64
att_vols:
	dc.b	64,59,54,50,46,42,38,35,32,30,27,25,23,21,19,18
	dc.b	16,15,14,13,12,11,10,9,8,7,7,6,6,5,5,4
	dc.b	4,4,3,3,3,3,2,2,2,2,2,1,1,1,1,1
	dc.b	1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0
	dcb.b	64,0
	even
square:
	rept	SQ_CYCLES
	dc.b	$7f,$80
	endr
