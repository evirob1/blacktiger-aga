; Black Tiger AGA - the sound board. Its Z80 program, translated
; (sound_code.s, tools/z80/translate.py --sound), runs in the 68k's
; interrupts; its two YM2203s become a register image (ym_regs) that the
; player turns into sound.
;
;   snd_init    the sound CPU's start-up: clears its RAM, sets the chips up
;   snd_timer   d0.l = time passed, in units of 72 YM clocks (20.1 us): runs
;               the two timers of YM2203 #1 and, when one overflows, the
;               sound CPU's interrupt routine ($0038)
;   snd_latch   (byte) the command the game wrote to port 0 (read at $C800)
;   snd_reset   d0.b = the game's port 4: bit 5 holds the sound CPU in reset
;               (the chips' timers keep running); its release starts it again
;
; Both keep all registers. The includer sets snd_a6 (the sound CPU's memory,
; halves swapped as for the game: (a6,Rn.w) with a6 = its address $8000, so
; its ROM is at a6; snd_init copies it there from snd_rom unless
; SND_ROM_IN_PLACE) and defines SNDLOG (macro: a YM write, d6 = chip, d0.b =
; register, d7.b = value; nothing in the game), ym_regs
; (2 x 256 bytes), ym_keyon (6 bytes), snd_rt (RT_SIZE) and z80_bad_jump.
;
; The sound CPU's main loop is ei / jr $0009 after the start-up; everything
; else happens in its interrupt, so it needs no context of its own: each
; interrupt runs to its reti on the caller's stack.

	Z80	SZC800,$c800		; the command latch
	Z80	SZE000,$e000		; YM2203 #1: status (timer flags)

snd_init:
	movem.l	d0-d7/a0-a6,-(sp)
	ifnd	SND_ROM_IN_PLACE
	lea	snd_rom(pc),a0		; the program: $0000-$7FFF
	move.l	snd_a6(pc),a1
	move.w	#$8000/4-1,d7
.c	move.l	(a0)+,(a1)+
	dbf	d7,.c
	endif
	lea	snd_rt(pc),a4
	move.l	snd_a6(pc),a6
	lea	snd_sp(pc),a0
	move.l	sp,(a0)
	bra	s_0000			; (its idle loop at $0009 comes back here)

s_0009:	move.l	snd_sp(pc),sp		; the idle loop: back to snd_init / snd_timer's caller
	movem.l	(sp)+,d0-d7/a0-a6
	rts

snd_timer:
	movem.l	d0-d7/a0-a6,-(sp)
	lea	snd_sp(pc),a0		; (a reset ends in the idle loop: back to here)
	move.l	sp,(a0)
	lea	snd_tvars(pc),a1
	move.l	d0,ST_LEFT(a1)
	move.l	d0,ST_ALL(a1)
	bne.s	.run
	clr.l	ST_BUSY(a1)		; (0: an interrupt now - tests)
.run	move.l	snd_a6(pc),a6
	move.b	snd_latch(pc),(SZC800,a6)
; in steps from one overflow to the next: each runs the interrupt routine
.step	lea	ym_regs(pc),a0
	lea	snd_tvars(pc),a1
	move.b	$27(a0),d1		; timer control
	move.l	ST_LEFT(a1),d5		; d5: the time to the next overflow (or
	btst	#0,d1			; the end)
	beq.s	.na
	cmp.l	ST_REMA(a1),d5
	ble.s	.na
	move.l	ST_REMA(a1),d5
.na	btst	#1,d1
	beq.s	.nb
	cmp.l	ST_REMB(a1),d5
	ble.s	.nb
	move.l	ST_REMB(a1),d5
.nb	tst.l	ST_BUSY(a1)
	ble.s	.nbusy
	cmp.l	ST_BUSY(a1),d5
	ble.s	.nbusy
	move.l	ST_BUSY(a1),d5
.nbusy	tst.l	d5
	bpl.s	.adv
	moveq	#0,d5
.adv	sub.l	d5,ST_LEFT(a1)
	sub.l	d5,ST_BUSY(a1)
	btst	#0,d1			; timer A running?
	beq.s	.ta
	sub.l	d5,ST_REMA(a1)
.a	tst.l	ST_REMA(a1)		; overflow: reload (the period now) and
	bgt.s	.ta			; flag it if enabled
	bsr	period_a
	add.l	d2,ST_REMA(a1)
	btst	#2,d1
	beq.s	.a
	bset	#0,ST_STATUS(a1)
	bra.s	.a
.ta	btst	#1,d1			; timer B running?
	beq.s	.irq
	sub.l	d5,ST_REMB(a1)
.b	tst.l	ST_REMB(a1)
	bgt.s	.irq
	bsr	period_b
	add.l	d2,ST_REMB(a1)
	btst	#3,d1
	beq.s	.b
	bset	#1,ST_STATUS(a1)
	bra.s	.b
.irq	tst.l	ST_BUSY(a1)		; still in the last interrupt: not yet
	bgt.s	.next
	tst.b	snd_held-snd_tvars(a1)	; held in reset: no interrupts
	bne.s	.next
	moveq	#3,d1			; the interrupt line follows the flags
	and.b	ST_STATUS(a1),d1
	beq.s	.next
	ifd	SND_HIFI
	tst.b	snd_hifi(pc)		; synthesised: the sound up to now, before
	beq.s	.nhf			; it changes (src/fm_synth.s)
	move.l	ST_ALL(a1),d1
	move.l	d1,d0
	sub.l	ST_LEFT(a1),d0
	bsr	sy_render
	moveq	#3,d1
	and.b	ST_STATUS(a1),d1
.nhf
	endif
	move.b	d1,(SZE000,a6)
	lea	snd_rt(pc),a4
	sub.l	a5,a5			; (the translation counts T-states in a5)
	bsr	s_0038
	move.l	snd_a6(pc),a6
	lea	snd_tvars(pc),a1
	move.l	a5,d0			; how long it took the Z80: the timers run
	add.l	#ISR_BASE,d0		; on meanwhile, their overflows only set
	divu.w	#72,d0			; the flags (a long one misses ticks)
	and.l	#$ffff,d0
	move.l	d0,ST_BUSY(a1)
.next	tst.l	ST_LEFT(a1)
	bgt	.step
	movem.l	(sp)+,d0-d7/a0-a6
	rts

ISR_BASE	equ	50		; T-states: taking the interrupt, reti
YM_WRITE	equ	170		; T-states: a YM write with its wait for the chip

; a0 = ym_regs -> d2.l = timer A's period: 1024 - (r24 << 2 | r25 & 3)
period_a:
	moveq	#0,d2
	move.b	$24(a0),d2
	lsl.w	#2,d2
	move.w	d3,-(sp)
	moveq	#3,d3
	and.b	$25(a0),d3
	or.w	d3,d2
	move.w	(sp)+,d3
	neg.w	d2
	add.w	#1024,d2
	rts
; -> timer B's: 16 * (256 - r26)
period_b:
	moveq	#0,d2
	move.b	$26(a0),d2
	neg.w	d2
	add.w	#256,d2
	lsl.w	#4,d2
	rts

; YM2203 register writes: $0153 (chip BC = $E000 / $E002; the wait for the
; chip is not needed) and $0162 (chip IY); A = register, D = value. Keep
; every register and the flags.
s_0153:	move.w	ccr,-(sp)
	movem.l	d6-d7/a0,-(sp)
	moveq	#2,d6
	and.w	d1,d6
	bra.s	ym_write
s_0162:	move.w	ccr,-(sp)
	movem.l	d6-d7/a0,-(sp)
	moveq	#2,d6
	and.w	d5,d6
ym_write:
	lea	YM_WRITE(a5),a5		; (its time, src/sound.s: snd_timer)
	lsr.w	#1,d6			; chip 0 / 1
	move.w	d2,d7
	lsr.w	#8,d7			; value
	SNDLOG
	cmp.b	#$27,d0			; (timers, key on / off: more to do)
	beq.s	.more
	cmp.b	#$28,d0
	beq.s	.more
	lsl.w	#8,d6
	move.b	d0,d6
	lea	ym_regs(pc),a0
	move.b	d7,(a0,d6.w)
	ifd	SND_HIFI
	tst.b	snd_hifi(pc)		; (synthesised: its settings again)
	beq.s	.nhf
	bsr	sy_reg
.nhf
	endif
	movem.l	(sp)+,d6-d7/a0
	move.w	(sp)+,ccr
	rts
.more	movem.l	d0-d5/a1,-(sp)
	lea	ym_regs(pc),a0
	move.w	d6,d1
	lsl.w	#8,d1
	moveq	#0,d2
	move.b	d0,d2
	add.w	d2,d1
	cmp.b	#$27,d0
	bne.s	.w
	tst.w	d6
	bne.s	.w
	move.b	(a0,d1.w),d3		; timer control: a timer started (load
	move.b	d7,(a0,d1.w)		; 0 -> 1) counts its period from now
	lea	snd_tvars(pc),a1
	not.b	d3
	and.b	d7,d3
	btst	#0,d3
	beq.s	.lb
	bsr	period_a
	move.l	d2,ST_REMA(a1)
.lb	btst	#1,d3
	beq.s	.rs
	bsr	period_b
	move.l	d2,ST_REMB(a1)
.rs	move.l	a1,a0			; reset flags
	btst	#4,d7
	beq.s	.ra
	bclr	#0,ST_STATUS(a0)
.ra	btst	#5,d7
	beq.s	.st
	bclr	#1,ST_STATUS(a0)
.st	moveq	#3,d1			; (status as the next read sees it)
	and.b	ST_STATUS(a0),d1
	move.b	d1,(SZE000,a6)
	bra.s	.x
.w	move.b	d7,(a0,d1.w)
.k	cmp.b	#$28,d0			; key on / off: d7 = slots << 4 | channel
	bne.s	.x
	ifd	SND_HIFI
	tst.b	snd_hifi(pc)		; (synthesised: in order, src/fm_synth.s)
	beq.s	.nhk
	bsr	sy_key
.nhk
	endif
	moveq	#3,d1
	and.w	d7,d1
	cmp.w	#3,d1
	beq.s	.x
	add.w	d6,d1
	add.w	d6,d1
	add.w	d6,d1			; channel 0-5
	lea	ym_keyon(pc),a0	; bits 0-3: slots on; bit 7: keyed on since
	lsr.b	#4,d7			; the player last looked (a quick off keeps it:
	beq.s	.off			; the note still starts). Keyed on while on
	moveq	#$0f,d2			; already: no new note (the chip ignores it;
	and.b	(a0,d1.w),d2		; the credit jingle's last note)
	bne.s	.on
	or.b	#$80,d7
.on	move.b	(a0,d1.w),d2
	and.b	#$80,d2
	or.b	d2,d7
	move.b	d7,(a0,d1.w)
	bra.s	.x
.off	and.b	#$80,(a0,d1.w)
.x	movem.l	(sp)+,d0-d5/a1
	movem.l	(sp)+,d6-d7/a0
	move.w	(sp)+,ccr
	rts

snd_reset:
	movem.l	d1/a0,-(sp)
	lea	snd_held(pc),a0
	btst	#5,d0
	sne	d1
	cmp.b	(a0),d1
	beq.s	.x			; no change
	move.b	d1,(a0)
	bne.s	.x			; now held
	bsr	snd_init		; released: start again
.x	movem.l	(sp)+,d1/a0
	rts

snd_ei:	st	RT_IE(a4)
	rts

snd_jp_hl:
	move.w	ccr,-(sp)
	move.w	d3,d7
	bsr.s	snd_lookup
	move.w	(sp)+,ccr
	jmp	(a0)

; d7.w = sound CPU address -> a0 = 68k code (keeps every other register)
snd_lookup:
	move.w	ccr,-(sp)
	movem.l	d0-d1/d6,-(sp)
	and.l	#$ffff,d7
	or.l	#$ff0000,d7
	lea	snd_table_count(pc),a0
	move.l	(a0)+,d1		; hi
	moveq	#0,d0			; lo
.loop	cmp.l	d1,d0
	bhs.s	.miss
	move.l	d0,d6
	add.l	d1,d6
	lsr.l	#1,d6
	cmp.l	(a0,d6.l*8),d7
	beq.s	.hit
	blo.s	.low
	move.l	d6,d0
	addq.l	#1,d0
	bra.s	.loop
.low	move.l	d6,d1
	bra.s	.loop
.hit	move.l	4(a0,d6.l*8),d6
	add.l	d6,a0
	movem.l	(sp)+,d0-d1/d6
	move.w	(sp)+,ccr
	rts
.miss	and.l	#$ffff,d7		; (bank $FD: the sound CPU)
	or.l	#$fd0000,d7
	bra	z80_bad_jump

; timers and the status they set
	rsreset
ST_REMA		rs.l	1		; time to timer A's next overflow
ST_REMB		rs.l	1
ST_LEFT		rs.l	1		; snd_timer: the time still to run
ST_BUSY		rs.l	1		; the interrupt routine still running for
ST_ALL		rs.l	1		; snd_timer: all of its time
ST_STATUS	rs.b	1		; bit 0: timer A flag, bit 1: timer B
		rs.b	1
ST_SIZE		rs.b	0
	cnop	0,4
snd_tvars:	ds.b	ST_SIZE
snd_sp:		dc.l	0
snd_a6:		dc.l	0		; the sound CPU's memory + $8000 (set by the includer)
snd_latch:	dc.b	0
snd_held:	dc.b	0
snd_hifi:	dc.b	0		; the chips synthesised (src/fm_synth.s), not samples
		even

	include	"sound_code.s"		; the translation (tools/z80/translate.py --sound)
