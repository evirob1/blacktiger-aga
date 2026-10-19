; Black Tiger AGA - runtime for the translated Z80 program (platform independent)
;
; The platform file that includes this one defines:
;   PLAT_IN  port    macro: d0.b = value read from Z80 I/O port
;   PLAT_OUT port    macro: Z80 I/O port write of d0.b
;   CYC n            macro: count n Z80 T-states (test build) or nothing
;   BOUNDARY         macro: mark a Z80 instruction boundary (test build) or nothing
;   z80_bad_jump     routine: d7 = unknown (bank<<16|address)
;   z80_ei           routine: Z80 "ei" (set RT_IE(a4), run a pending interrupt)
;   plat_irq         68k interrupt handler that calls rt_irq_body
;
; Register use while Z80 code runs (docs/TRANSLATOR.md):
;   d0 = A, d1 = BC, d2 = DE, d3 = HL, d4 = IX, d5 = IY, d6/d7/a0 scratch,
;   a1-a3 = BC'/DE'/HL', a4 = runtime variables, a5 = Z80 cycle counter (test
;   build only), a6 = Z80 memory + $8000 (halves swapped: (a6,Rn.w) addressing).
;
; The game runs like the arcade board: rt_init runs the reset code, which ends
; in the scheduler's endless loop; the vblank interrupt (rt_irq_body, called by
; the platform's interrupt handler) wakes tasks.

Z80	macro			; Z80 address -> offset from a6
\1	equ	((\2)^$8000)-$8000
	endm

	Z80	ZE880,$e880		; scheduler task slots
	Z80	ZE886,$e886		; "rescan" flag set by the interrupt
	Z80	ZE887,$e887		; current task slot
	Z80	Z8000,$8000		; banked ROM window
	Z80	ZC000,$c000		; background RAM window

; runtime variables (a4 relative)
RT_BANK		equ	0	; b  ROM bank at $8000
RT_BGBANK	equ	1	; b  background RAM bank at $C000
RT_IE		equ	2	; b  Z80 interrupt enable ($FF = ei)
RT_PENDING	equ	3	; b  interrupt waiting for ei (Amiga)
RT_ALT_A	equ	4	; b  A'
RT_ALT_F	equ	6	; w  F' (as a 68k CCR)
RT_TASK_SP	equ	8	; 16 x l  68k stack of each sleeping task

;------------------------------------------------------------------------------
; header: entry points and data offsets for the loaders
rt_header:
	bra.w	rt_init			; +0  power on (never returns)
	bra.w	rt_irq_body		; +4  Z80 interrupt (all registers saved by the caller)
	dc.l	z80mem-rt_header	; +8  Z80 memory image (halves swapped)
	dc.l	bgram-rt_header		; +12 16K background RAM (all four banks)
	dc.l	rt_vars-rt_header	; +16 runtime variables
	dc.l	plat_irq-rt_header	; +20 platform interrupt handler (68k level 3)

;------------------------------------------------------------------------------
rt_init:
	lea	rt_vars(pc),a4
	lea	z80mem+$8000(pc),a6
	lea	z80rom(pc),a0		; fixed ROM -> Z80 $0000-$7FFF
	move.l	a6,a1
	move.w	#$8000/4-1,d7
.rom	move.l	(a0)+,(a1)+
	dbf	d7,.rom
	moveq	#0,d0
	bsr	set_bank
	sub.l	a5,a5
	sf	RT_IE(a4)
	lea	sched_stack_top(pc),sp
	bra	z_0000			; Z80 reset: di / im 1 / jp $014c

; the Z80 interrupt: called with all 68k registers saved (a5 must stay live)
rt_irq_body:
	lea	rt_vars(pc),a4
	lea	z80mem+$8000(pc),a6
	sf	RT_IE(a4)		; accepting an interrupt clears IFF
	CYC	13			; IM 1 acknowledge
	bra	z_0038			; ends with ei / ret

;------------------------------------------------------------------------------
; Scheduler: replaces Z80 $00B3-$00F5 and $0116-$0134, step for step (cycle
; counts and di/ei windows included) so interrupts land where they would on
; the Z80. 16 slots of 8 bytes at $E880:
;   +0 state (0 free, 1 sleeping, 2 running, 4 ready, 8 new), +1 sleep count,
;   +2/3 entry address (new task) or saved Z80 SP (not modelled here).
; A sleeping task's 68k registers are on its own stack (RT_TASK_SP).

; Every Z80 instruction of the loop gets a BOUNDARY (interrupt check point,
; before the instruction) and its T-states.
z_00b3:
	BOUNDARY			; ld sp,$e880
	CYC	10
	lea	sched_stack_top(pc),sp
sched_00b6:
	BOUNDARY			; xor a
	CYC	4
	BOUNDARY			; ld ($e886),a
	CYC	13
	clr.b	(ZE886,a6)
	BOUNDARY			; ld hl,$e880
	CYC	10
	lea	(ZE880,a6),a0
	BOUNDARY			; ld de,$0008
	CYC	10
	BOUNDARY			; ld bc,$1000
	CYC	10
	moveq	#0,d6			; C = slot
sched_00c3:
	BOUNDARY			; di
	CYC	4
	sf	RT_IE(a4)
	BOUNDARY			; ld a,($e886)
	CYC	13
	BOUNDARY			; and a
	CYC	4
	BOUNDARY			; jr nz,$00b6
	CYC	7
	tst.b	(ZE886,a6)
	beq.s	.go
	CYC	5
	bra	sched_00b6
.go	BOUNDARY			; ld a,(hl)
	CYC	7
	BOUNDARY			; cp $04
	CYC	7
	BOUNDARY			; jr nc,$00d6
	CYC	7
	cmp.b	#4,(a0)
	bhs	sched_00d6
	BOUNDARY			; ei
	CYC	4
	st	RT_IE(a4)
	BOUNDARY			; add hl,de
	CYC	11
	addq.l	#8,a0
	BOUNDARY			; inc c
	CYC	4
	addq.w	#1,d6
	BOUNDARY			; djnz $00c3
	CYC	8
	cmp.w	#16,d6
	beq.s	.wrap
	CYC	5
	bra	sched_00c3
.wrap	BOUNDARY			; jr $00b6
	CYC	12
	bra	sched_00b6

sched_00d6:				; run slot d6 (a0 -> slot); interrupts are off
	CYC	5+4+4+13+7+10+6+10+6+7+6+7+4+7
	sf	RT_IE(a4)
	move.b	d6,(ZE887,a6)
	move.b	(a0),d7			; old state
	move.b	#2,(a0)
	clr.b	1(a0)
	cmp.b	#8,d7
	beq.s	.start
	CYC	12+6+10+10+10+10+14+14+4 ; jr nz taken, ld sp,hl, pops, ei
	move.l	RT_TASK_SP(a4,d6.w*4),sp
	movem.l	(sp)+,d0-d5
	move.w	(sp)+,ccr
	st	RT_IE(a4)
	BOUNDARY
	CYC	10			; ret
	rts				; returns from the task's call to $0116

.start	CYC	7+4			; jr nz (not taken) / jp (hl)
	moveq	#0,d7			; registers as the Z80 scheduler leaves them
	move.b	3(a0),d7
	lsl.w	#8,d7
	move.b	2(a0),d7
	move.w	d7,d3			; HL = entry
	move.w	d6,d2
	lsl.w	#3,d2
	add.w	#$e883,d2		; DE = slot + 3
	moveq	#16,d1
	sub.w	d6,d1
	lsl.w	#8,d1
	move.b	d6,d1			; B = slots left, C = slot
	moveq	#8,d0			; A = old state
	lea	task_stacks(pc),a0	; default stack until the task loads its own
	move.w	d6,d7
	addq.w	#1,d7
	mulu.w	#1024,d7
	add.l	d7,a0
	move.l	a0,sp
	move.w	d3,d7
	bsr	z80_lookup
	move	#4,ccr			; Z set (cp $08)
	jmp	(a0)

; Z80 $0116: sleep for A frames
z_0116:
	BOUNDARY			; (an interrupt can come before its di)
	CYC	4+15+15+11+11+11+11+11+17+67+10+6+10+7+6+4+10+11+4+7+6+7+10
	sf	RT_IE(a4)
	move.w	ccr,-(sp)
	movem.l	d0-d5,-(sp)
	moveq	#0,d6
	move.b	(ZE887,a6),d6
	lea	(ZE880,a6),a0
	lea	(a0,d6.w*8),a0
	move.b	#1,(a0)
	move.b	d0,1(a0)
	move.l	sp,RT_TASK_SP(a4,d6.w*4)
	bra	z_00b3

;------------------------------------------------------------------------------
; computed jumps: jp (hl) / (ix) / (iy)
z80_jp_hl:
	move.w	d3,d7
	bra.s	z80_jp
z80_jp_ix:
	move.w	d4,d7
	bra.s	z80_jp
z80_jp_iy:
	move.w	d5,d7
z80_jp:
	move.w	ccr,-(sp)
	bsr.s	z80_lookup
	move.w	(sp)+,ccr
	jmp	(a0)

; d7.w = Z80 address -> a0 = 68k code. Keeps every other register and the CCR.
z80_lookup:
	move.w	ccr,-(sp)
	movem.l	d0-d1/d6,-(sp)
	and.l	#$ffff,d7
	cmp.w	#$8000,d7
	blo.s	.fixed
	cmp.w	#$c000,d7
	bhs.s	.fixed
	moveq	#0,d6
	move.b	RT_BANK(a4),d6
	swap	d6
	or.l	d6,d7
	bra.s	.search
.fixed	or.l	#$ff0000,d7
.search	lea	z80_table_count(pc),a0
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
.miss	bra	z80_bad_jump

z80_unknown_bank:
	move.l	#$fe0000,d7
	bra	z80_bad_jump

;------------------------------------------------------------------------------
; ROM bank switch: copy bank d0 (0-15) into Z80 $8000-$BFFF
set_bank:
	movem.l	d0/d7/a0-a1,-(sp)
	and.w	#$0f,d0
	move.b	d0,RT_BANK(a4)
	moveq	#0,d7
	move.b	d0,d7
	moveq	#14,d0
	lsl.l	d0,d7			; * $4000
	lea	z80banks(pc),a0
	add.l	d7,a0
	lea	(Z8000,a6),a1
	move.w	#$4000/4-1,d7
.c	move.l	(a0)+,(a1)+
	dbf	d7,.c
	movem.l	(sp)+,d0/d7/a0-a1
	rts

; background RAM bank: the Z80 sees one 4K bank of 16K at $C000
set_bg_bank:
	movem.l	d0/d7/a0-a2,-(sp)
	and.w	#3,d0
	moveq	#0,d7
	move.b	RT_BGBANK(a4),d7
	cmp.b	d7,d0
	beq.s	.same
	move.b	d0,RT_BGBANK(a4)
	lea	bgram(pc),a1
	lsl.w	#8,d7
	lsl.w	#4,d7
	lea	(a1,d7.w),a2		; old bank: window -> bgram
	lea	(ZC000,a6),a0
	move.w	#$1000/4-1,d7
.out	move.l	(a0)+,(a2)+
	dbf	d7,.out
	lsl.w	#8,d0
	lsl.w	#4,d0
	lea	(a1,d0.w),a2		; new bank: bgram -> window
	lea	(ZC000,a6),a0
	move.w	#$1000/4-1,d7
.in	move.l	(a2)+,(a0)+
	dbf	d7,.in
.same	movem.l	(sp)+,d0/d7/a0-a2
	rts

;------------------------------------------------------------------------------
; I/O ports (Z80 in/out never change flags)
IN_PORT	macro
io_in_\1:
	move.w	ccr,-(sp)
	PLAT_IN	$\1
	move.w	(sp)+,ccr
	rts
	endm

OUT_PORT macro
io_out_\1:
	move.w	ccr,-(sp)
	PLAT_OUT $\1
	move.w	(sp)+,ccr
	rts
	endm

	IN_PORT	00
	IN_PORT	01
	IN_PORT	02
	IN_PORT	03
	IN_PORT	04
	IN_PORT	05
	IN_PORT	07
	OUT_PORT 00
	OUT_PORT 02
	OUT_PORT 03
	OUT_PORT 04
	OUT_PORT 06
	OUT_PORT 07
	OUT_PORT 08
	OUT_PORT 09
	OUT_PORT 0a
	OUT_PORT 0b
	OUT_PORT 0c
	OUT_PORT 0e

io_out_01:				; ROM bank
	move.w	ccr,-(sp)
	PLAT_OUT $01
	bsr	set_bank
	move.w	(sp)+,ccr
	rts

io_out_0d:				; background RAM bank
	move.w	ccr,-(sp)
	PLAT_OUT $0d
	bsr	set_bg_bank
	move.w	(sp)+,ccr
	rts

;------------------------------------------------------------------------------
	cnop	0,4
rt_vars:	ds.b	RT_TASK_SP+16*4
	cnop	0,4
		ds.b	1024
sched_stack_top:
