; Black Tiger AGA - the translated arcade program running on the A1200
;
; Boot: src/boot.s loads this file into chip RAM (plus BSS_SIZE cleared bytes)
; and jumps to the start with A6 = ExecBase.
;
; This file is the Amiga "hardware" for the translated Z80 program
; (src/rt_core.s + build/game/game.s):
;  * the vblank interrupt runs the Z80 interrupt (or leaves it pending while
;    the program has interrupts disabled; z80_ei delivers it)
;  * I/O ports: joystick / keyboard / DIP switches / protection MCU answers
;  * display, rebuilt every vblank from the arcade video RAM:
;      background  8 bitplanes, tiles drawn from background RAM, hardware scroll;
;                  both map layouts (64 x 128 and 128 x 64 tiles)
;      text layer  4 hardware sprites 64 pixels wide, 2 bitplanes like the
;                  arcade characters, colours per character row by the copper
;      palette     all 256 background colours from palette RAM, every frame
;    Not yet: game sprites, background priority, sound.
;
; Controls: joystick in port 2 - fire attacks, second button (or Space) jumps.
;           Keyboard: 5 = coin, 1 = 1 player start, 2 = 2 players.

	machine	68020

CUSTOM		equ	$dff000
DMACONR		equ	$002
VPOSR		equ	$004
VHPOSR		equ	$006
JOY1DAT		equ	$00c
POTINP		equ	$016
INTENAR		equ	$01c
INTREQR		equ	$01e
POTGO		equ	$034
BLTCON0		equ	$040
BLTCON1		equ	$042
BLTAFWM		equ	$044
BLTAPT		equ	$050
BLTDPT		equ	$054
BLTSIZE		equ	$058
BLTAMOD		equ	$064
BLTDMOD		equ	$066
COP1LC		equ	$080
COPJMP1		equ	$088
DIWSTRT		equ	$08e
DIWSTOP		equ	$090
DDFSTRT		equ	$092
DDFSTOP		equ	$094
DMACON		equ	$096
INTENA		equ	$09a
INTREQ		equ	$09c
BPL1PTH		equ	$0e0
BPLCON0		equ	$100
BPLCON1		equ	$102
BPLCON2		equ	$104
BPLCON3		equ	$106
BPL1MOD		equ	$108
BPL2MOD		equ	$10a
BPLCON4		equ	$10c
SPR0PTH		equ	$120
COLOR00		equ	$180
FMODE		equ	$1fc
CIAA_PRA	equ	$bfe001
CIAA_SDR	equ	$bfec01
CIAA_ICR	equ	$bfed01
CIAA_CRA	equ	$bfee01

; Background buffer: 24 tile columns (48 bytes) x 256 lines per plane, wrapping
; in both directions. Vertically the copper changes the modulo for one line;
; horizontally the bitplane pointer simply moves on: map column C is drawn at
; byte 2*C of its tile row, so it shares memory with column C-24 one line
; further down, which is never on screen at the same time (17 columns are).
VIEW_H		equ	224
NPLANES		equ	8
LINEB		equ	48
BUFH		equ	256
PLANESZ		equ	LINEB*BUFH
PLANEALLOC	equ	16+PLANESZ+256+64	; slack before, map width after
FETCHB		equ	36			; 9 x 32 pixels (FMODE=1)
MODULO		equ	LINEB-FETCHB
WRAPMOD		equ	MODULO-PLANESZ
NCOLSLOT	equ	24
DISP_Y0		equ	$3c
COPSIZE		equ	4096
PALSECT		equ	8*(1+32)*4		; palette section at the start of each copper list
TXROWS		equ	28			; arcade text rows 2-29 are visible
TXSPR_SIZE	equ	16+VIEW_H*16+16		; 64-bit sprite: control, lines, end
SPR_H0		equ	$a0			; sprite x of the left window edge

; platform variables (a4 relative inside the display code)
		rsreset
pv_io		rs.b	16			; last value written to each I/O port
pv_in0		rs.b	1			; port 0 value (active low)
pv_in1		rs.b	1			; port 1 value (active low)
pv_layout	rs.w	1			; 0: 64 x 128 tiles, 1: 128 x 64 (port $0E)
pv_vx		rs.w	1			; view position in the map (pixels)
pv_vy		rs.w	1
pv_copidx	rs.w	1
pv_rowpal	rs.b	TXROWS*4		; text palette per row and sprite
pv_rgb		rs.w	256			; background colours, 12 bit
pv_txrgb	rs.w	128			; text colours (palette entries $300-$37F)
pv_paldirty	rs.w	1			; copper lists whose palette section is stale
pv_keys		rs.b	128
pv_size		rs.b	0

;------------------------------------------------------------------------------
start:
	lea	super(pc),a5
	jsr	-30(a6)			; Exec Supervisor(): continue in supervisor mode
super:
	move.w	#$2700,sr
	lea	plat_stack_top(pc),sp
	lea	CUSTOM,a6
	move.w	#$7fff,INTENA(a6)
	move.w	#$7fff,INTREQ(a6)
	move.w	#$7fff,DMACON(a6)
	moveq	#1,d0
	movec	d0,cacr			; instruction cache on
	movec	vbr,a0
	lea	lev2(pc),a1
	move.l	a1,$68(a0)
	lea	lev3(pc),a1
	move.l	a1,$6c(a0)
	move.b	#$7f,CIAA_ICR		; keyboard: CIA-A serial port interrupt only
	tst.b	CIAA_ICR
	move.b	#$88,CIAA_ICR
	and.b	#$bf,CIAA_CRA
	move.w	#$ff00,POTGO(a6)	; second fire button readable on POTINP

	bsr	init_display
	move.w	#$87e0,DMACON(a6)	; bitplanes, copper, blitter (nasty), sprites
	move.w	#$c028,INTENA(a6)	; vertical blank + keyboard
	move.w	#$2000,sr
	bra	rt_init			; Z80 power on (never returns)

;------------------------------------------------------------------------------
; platform hooks for rt_core.s
PLAT_IN	macro
	moveq	#\1,d0
	bsr	plat_in
	endm

PLAT_OUT macro
	move.l	d7,-(sp)
	moveq	#\1,d7
	bsr	plat_out
	move.l	(sp)+,d7
	endm

CYC	macro
	endm

BOUNDARY macro
	endm

PLAT_EI	macro				; enable + deliver a vblank that came while disabled
	bsr	z80_ei
	endm

	include	"rt_core.s"

; d0 = port -> d0.b = value. Keeps every other register. (a6 = Z80 memory)
plat_in:
	move.l	a0,-(sp)
	lea	pvars(pc),a0
	tst.w	d0
	beq.s	.p0
	cmp.w	#1,d0
	beq.s	.p1
	cmp.w	#4,d0
	beq.s	.dsw1
	cmp.w	#5,d0
	beq.s	.dsw2
	cmp.w	#7,d0
	beq.s	.mcu
	moveq	#-1,d0			; IN2 (player 2), DSW0 (1 coin 1 credit, no flip)
	bra.s	.x
.p0	move.b	pv_in0(a0),d0		; start / coin (vblank bit always set)
	bra.s	.x
.p1	move.b	pv_in1(a0),d0		; joystick
	bra.s	.x
.dsw1	moveq	#$6f,d0			; 3 lives, difficulty 5, demo sound, continue, upright
	bra.s	.x
.dsw2	moveq	#$01,d0			; freeze off
	bra.s	.x
.mcu	moveq	#$0f,d0			; protection MCU: byte n of the table at $0AB8
	and.b	pv_io+7(a0),d0
	move.b	($0ab8,a6,d0.w),d0
.x	move.l	(sp)+,a0
	rts

plat_out:
	move.l	a0,-(sp)
	lea	pvars(pc),a0
	move.b	d0,pv_io(a0,d7.w)
	move.l	(sp)+,a0
	rts

; Z80 ei: enable, and deliver an interrupt that came while disabled
z80_ei:
	move.w	sr,-(sp)
	ori.w	#$0700,sr
	st	RT_IE(a4)
	tst.b	RT_PENDING(a4)
	beq.s	.x
	sf	RT_PENDING(a4)
	move.w	(sp),sr			; back to the caller's interrupt level
	movem.l	d0-d7/a0/a2-a6,-(sp)
	bsr	rt_irq_body
	movem.l	(sp)+,d0-d7/a0/a2-a6
.x	move.w	(sp)+,sr
	rts

; something jumped to Z80 code that was never translated: stop with a red screen
z80_bad_jump:
	move.w	#$2700,sr
	lea	CUSTOM,a6
	move.w	#$0080,DMACON(a6)
.red	move.w	#$0f00,COLOR00(a6)
	bra.s	.red

plat_irq:				; (rt_core header; the Amiga uses lev3)
	rte

;------------------------------------------------------------------------------
; level 3: vertical blank -> update the display, then the Z80 interrupt
lev3:
	btst	#5,CUSTOM+INTREQR+1
	beq.s	.other
	move.w	#$0020,CUSTOM+INTREQ
	move.w	#$0020,CUSTOM+INTREQ
	movem.l	d0-d7/a0/a2-a6,-(sp)	; a1 (bank pointer) is left alone
	bsr	vblank_display
	lea	rt_vars(pc),a4
	tst.b	RT_IE(a4)
	beq.s	.pend
	bsr	rt_irq_body
	bra.s	.done
.pend	st	RT_PENDING(a4)
.done	movem.l	(sp)+,d0-d7/a0/a2-a6
	rte
.other	move.w	#$0050,CUSTOM+INTREQ	; copper / blitter
	rte

; level 2: keyboard (CIA-A serial port)
lev2:
	movem.l	d0-d1/a0,-(sp)
	move.b	CIAA_ICR,d0
	btst	#3,d0
	beq.s	.x
	move.b	CIAA_SDR,d1
	or.b	#$40,CIAA_CRA		; handshake
	not.b	d1
	ror.b	#1,d1
	lea	pvars+pv_keys(pc),a0
	moveq	#$7f,d0
	and.b	d1,d0
	tst.b	d1
	smi	d1
	not.b	d1			; $ff = pressed
	move.b	d1,(a0,d0.w)
	moveq	#2,d1			; hold the handshake for ~3 lines
.h1	move.b	CUSTOM+VHPOSR,d0
.h2	cmp.b	CUSTOM+VHPOSR,d0
	beq.s	.h2
	dbf	d1,.h1
	and.b	#$bf,CIAA_CRA
.x	move.w	#$0008,CUSTOM+INTREQ
	move.w	#$0008,CUSTOM+INTREQ
	movem.l	(sp)+,d0-d1/a0
	rte

;------------------------------------------------------------------------------
init_display:
	lea	pvars(pc),a4
	lea	rev_table(pc),a0	; bit reversal table for x-flipped tiles
	moveq	#0,d0
.rv	moveq	#7,d2
	moveq	#0,d1
	move.b	d0,d3
.rb	lsr.b	#1,d3
	addx.b	d1,d1
	dbf	d2,.rb
	move.b	d1,(a0,d0.w)
	addq.b	#1,d0
	bne.s	.rv
	; text sprites: control words, 64 pixels wide, VIEW_H lines from DISP_Y0
	lea	txspr(pc),a0
	move.w	#SPR_H0,d2
	moveq	#3,d7
.sp	move.w	#DISP_Y0,d0
	move.w	#DISP_Y0+VIEW_H,d1
	bsr	sprite_ctl
	lea	TXSPR_SIZE(a0),a0
	add.w	#64,d2
	dbf	d7,.sp
	clr.w	pv_vx(a4)
	clr.w	pv_vy(a4)
	move.w	#-1,pv_layout(a4)	; forces a full redraw
	lea	colpart(pc),a0		; per map column: byte offset in its row << 16
	moveq	#0,d0			; | (C mod 24) * 4 (shadow offset)
.cp	moveq	#0,d3
	move.w	d0,d3
	divu.w	#NCOLSLOT,d3
	swap	d3
	lsl.w	#2,d3
	move.w	d0,d1
	and.w	#15,d1
	move.w	d0,d2
	and.w	#$30,d2
	lsl.w	#4,d2
	add.w	d2,d1
	add.w	d1,d1
	move.w	d1,(a0)			; layout 0
	move.w	d3,2(a0)
	move.w	d0,d1
	and.w	#15,d1
	move.w	d0,d2
	and.w	#$70,d2
	lsl.w	#4,d2
	add.w	d2,d1
	add.w	d1,d1
	move.w	d1,512(a0)		; layout 1
	move.w	d3,514(a0)
	addq.l	#4,a0
	addq.w	#1,d0
	cmp.w	#128,d0
	bne.s	.cp
	moveq	#-1,d0
	move.b	d0,pv_in0(a4)
	move.b	d0,pv_in1(a4)
	move.w	#2,pv_paldirty(a4)
	bsr	build_copper
	lea	CUSTOM,a6
	move.l	coplist_ptr(pc),COP1LC(a6)
	move.w	d0,COPJMP1(a6)
	rts

; a0 = sprite data, d0 = first line, d1 = line after the last, d2 = x
sprite_ctl:
	move.w	d0,d3
	lsl.w	#8,d3
	move.w	d2,d4
	lsr.w	#1,d4
	move.b	d4,d3
	move.w	d3,(a0)			; POS: SV7-0, SH8-1
	move.w	d1,d3
	lsl.w	#8,d3			; EV7-0
	move.w	d0,d4
	lsr.w	#8,d4
	and.w	#1,d4
	lsl.w	#2,d4
	or.w	d4,d3			; SV8
	move.w	d1,d4
	lsr.w	#8,d4
	and.w	#1,d4
	add.w	d4,d4
	or.w	d4,d3			; EV8
	move.w	d2,d4
	and.w	#1,d4
	or.w	d4,d3			; SH0
	move.w	d3,8(a0)		; CTL (64-bit control words)
	rts

;------------------------------------------------------------------------------
; once per frame, in the vertical blank interrupt
	Z80	ZD000,$d000
	Z80	ZD400,$d400
	Z80	ZD800,$d800
	Z80	ZDC00,$dc00

vblank_display:
	lea	pvars(pc),a4
	lea	z80mem+$8000(pc),a5
	lea	CUSTOM,a6
	bsr	read_inputs
	bsr	update_palette
	bsr	update_text
	bsr	update_background
	bsr	build_copper
	move.l	coplist_ptr(pc),COP1LC(a6)	; used from the next frame
	rts

read_inputs:
	moveq	#-1,d1			; port 1: active low
	move.w	JOY1DAT(a6),d0
	lea	pv_keys(a4),a0
	btst	#1,d0
	bne.s	.r
	tst.b	$4e(a0)
	beq.s	.nr
.r	bclr	#0,d1
.nr	btst	#9,d0
	bne.s	.l
	tst.b	$4f(a0)
	beq.s	.nl
.l	bclr	#1,d1
.nl	move.w	d0,d2
	lsr.w	#1,d2
	eor.w	d0,d2
	btst	#0,d2
	bne.s	.d
	tst.b	$4d(a0)
	beq.s	.nd
.d	bclr	#2,d1
.nd	btst	#8,d2
	bne.s	.u
	tst.b	$4c(a0)
	beq.s	.nu
.u	bclr	#3,d1
.nu	btst	#7,CIAA_PRA
	beq.s	.f1
	tst.b	$63(a0)			; ctrl
	beq.s	.nf1
.f1	bclr	#4,d1
.nf1	btst	#6,POTINP(a6)		; second button (pin 9)
	beq.s	.f2
	tst.b	$40(a0)			; space
	bne.s	.f2
	tst.b	$64(a0)			; left alt
	beq.s	.nf2
.f2	bclr	#5,d1
.nf2	move.b	d1,pv_in1(a4)
	moveq	#-1,d1			; port 0
	tst.b	$01(a0)
	beq.s	.s1
	bclr	#0,d1
.s1	tst.b	$02(a0)
	beq.s	.s2
	bclr	#1,d1
.s2	tst.b	$05(a0)
	beq.s	.c1
	bclr	#6,d1
.c1	tst.b	$06(a0)
	beq.s	.c2
	bclr	#7,d1
.c2	move.b	d1,pv_in0(a4)
	rts

;------------------------------------------------------------------------------
; text layer: arcade rows 2-29 into the four sprites. Rows are compared with
; the shadow copy 4 bytes at a time; only a changed row is looked at per cell.
update_text:
	lea	txshadow(pc),a3
	moveq	#0,d5			; row 0-27
.row	move.w	d5,d0
	addq.w	#2,d0
	lsl.w	#5,d0			; first cell of the row
	lea	(ZD000,a5,d0.w),a0
	lea	(a3,d0.w),a2
	moveq	#7,d1
.cc	cmpm.l	(a0)+,(a2)+
	bne.s	.cells
	dbf	d1,.cc
	lea	(ZD400,a5,d0.w),a0
	lea	$400(a3,d0.w),a2
	moveq	#7,d1
.ca	cmpm.l	(a0)+,(a2)+
	bne.s	.cells
	dbf	d1,.ca
	bra.s	.same
.cells	moveq	#0,d6			; column 0-31
.col	move.w	d5,d0
	addq.w	#2,d0
	lsl.w	#5,d0
	add.w	d6,d0			; arcade cell index
	move.b	(ZD000,a5,d0.w),d1	; code
	move.b	(ZD400,a5,d0.w),d2	; attribute
	cmp.b	(a3,d0.w),d1
	bne.s	.chg
	cmp.b	$400(a3,d0.w),d2
	beq.s	.next
.chg	move.b	d1,(a3,d0.w)
	move.b	d2,$400(a3,d0.w)
	bsr	draw_char
.next	addq.w	#1,d6
	cmp.w	#32,d6
	bne.s	.col
	bsr	row_palettes
.same	addq.w	#1,d5
	cmp.w	#TXROWS,d5
	bne.s	.row
	rts

; d1 = code low byte, d2 = attribute, d5 = row, d6 = column
draw_char:
	movem.l	d0-d2/a0/a2,-(sp)
	moveq	#0,d0
	move.b	d2,d0
	and.w	#$e0,d0
	lsl.w	#3,d0
	move.b	d1,d0			; character number
	lsl.w	#4,d0
	lea	chars(pc),a2
	add.w	d0,a2			; 8 x (plane A, plane B)
	lea	txspr+16(pc),a0
	move.w	d6,d0
	lsr.w	#3,d0
	mulu.w	#TXSPR_SIZE,d0
	add.l	d0,a0
	moveq	#7,d0
	and.w	d6,d0
	add.w	d0,a0
	move.w	d5,d0
	lsl.w	#7,d0			; 8 lines x 16 bytes
	add.w	d0,a0
	moveq	#7,d0
.l	move.b	(a2)+,(a0)
	move.b	(a2)+,8(a0)
	lea	16(a0),a0
	dbf	d0,.l
	movem.l	(sp)+,d0-d2/a0/a2
	rts

; text colours for row d5: per sprite, the palette of its first visible character
row_palettes:
	movem.l	d0-d3/d6/a0/a3,-(sp)
	lea	pv_rowpal(a4),a0
	move.w	d5,d0
	lsl.w	#2,d0
	add.w	d0,a0
	lea	charblank(pc),a3
	moveq	#0,d6			; column
.blk	moveq	#0,d3			; palette (0 if the block is empty)
	moveq	#7,d2
.c	move.w	d5,d0
	addq.w	#2,d0
	lsl.w	#5,d0
	add.w	d6,d0			; cell
	addq.w	#1,d6
	moveq	#0,d1
	move.b	(ZD400,a5,d0.w),d1	; attribute
	and.w	#$e0,d1
	lsl.w	#3,d1
	move.b	(ZD000,a5,d0.w),d1	; character number
	tst.b	(a3,d1.w)
	bne.s	.blank
	moveq	#$1f,d3
	and.b	(ZD400,a5,d0.w),d3
	add.w	d2,d6			; skip the rest of the block
	bra.s	.set
.blank	dbf	d2,.c
.set	move.b	d3,(a0)+
	cmp.w	#32,d6
	blo.s	.blk
	movem.l	(sp)+,d0-d3/d6/a0/a3
	rts

;------------------------------------------------------------------------------
; background: every visible cell is compared with what its buffer slot holds
; (map row, map column, tile word); anything different is drawn. That covers
; scrolling in any direction, changed tiles and layout switches alike.
update_background:
	moveq	#1,d0
	and.b	pv_io+$e(a4),d0		; layout
	cmp.w	pv_layout(a4),d0
	beq.s	.same
	move.w	d0,pv_layout(a4)
	lea	bgshadow(pc),a0		; new layout: nothing in the buffer is valid
	move.w	#16*NCOLSLOT-1,d1
.inv	move.l	#-1,(a0)+
	dbf	d1,.inv
.same	move.w	#1024,d2		; map width in pixels
	move.w	#2048,d3		; and height
	tst.w	d0
	beq.s	.l0
	exg	d2,d3
.l0	moveq	#0,d0
	move.b	pv_io+9(a4),d0
	lsl.w	#8,d0
	move.b	pv_io+8(a4),d0
	move.w	d2,d1
	subq.w	#1,d1
	and.w	d1,d0
	sub.w	#256,d2
	cmp.w	d2,d0
	bls.s	.xok
	move.w	d2,d0			; (no horizontal wrap)
.xok	move.w	d0,pv_vx(a4)
	moveq	#0,d0
	move.b	pv_io+$b(a4),d0
	lsl.w	#8,d0
	move.b	pv_io+$a(a4),d0
	add.w	#16,d0			; arcade visible area starts at line 16
	subq.w	#1,d3
	and.w	d3,d0
	move.w	d0,pv_vy(a4)

	bsr	blit_setup
	move.w	pv_vy(a4),d6
	lsr.w	#4,d6			; first visible map row
	move.w	pv_vy(a4),d7
	add.w	#VIEW_H-1,d7
	lsr.w	#4,d7
	sub.w	d6,d7			; rows - 1
.row	movem.w	d6-d7,-(sp)
	bsr	bg_row
	movem.w	(sp)+,d6-d7
	addq.w	#1,d6
	dbf	d7,.row
	rts

; check / draw the visible cells of map row d6 (unwrapped; used mod map height)
bg_row:
	move.w	d6,d5
	moveq	#15,d0
	and.w	d0,d5			; buffer slot
	tst.w	pv_layout(a4)
	bne.s	.r1
	and.w	#127,d6
	move.w	d6,d0
	and.w	#15,d0
	lsl.w	#5,d0
	move.w	d6,d1
	and.w	#$70,d1
	lsl.w	#7,d1
	bra.s	.rc
.r1	and.w	#63,d6
	move.w	d6,d0
	and.w	#15,d0
	lsl.w	#5,d0
	move.w	d6,d1
	and.w	#$30,d1
	lsl.w	#8,d1
.rc	add.w	d1,d0			; byte offset of the row in the 16K
	move.w	d0,d1
	lsr.w	#8,d1
	lsr.w	#4,d1			; 4K bank
	cmp.b	rt_vars+RT_BGBANK(pc),d1
	beq.s	.live
	lea	bgram(pc),a2
	add.w	d0,a2
	bra.s	.got
.live	and.w	#$0fff,d0
	lea	(ZC000,a5),a2		; the bank the Z80 sees at $C000
	add.w	d0,a2
.got	lea	colpart(pc),a0
	tst.w	pv_layout(a4)
	beq.s	.cl0
	lea	512(a0),a0
.cl0	lea	bgshadow(pc),a3
	move.w	d5,d0
	mulu.w	#NCOLSLOT*4,d0
	add.w	d0,a3			; shadow of this slot
	move.w	pv_vx(a4),d4
	lsr.w	#4,d4			; first visible column
	move.w	pv_vx(a4),d7
	add.w	#255,d7
	lsr.w	#4,d7
	sub.w	d4,d7			; columns - 1
.col	move.l	(a0,d4.w*4),d1
	move.w	d1,d2			; shadow offset
	swap	d1
	move.w	(a2,d1.w),d1		; tile word: code << 8 | attribute
	move.w	d6,d0
	lsl.w	#8,d0
	or.w	d4,d0
	swap	d0
	move.w	d1,d0			; key: row << 24 | column << 16 | tile
	cmp.l	(a3,d2.w),d0
	beq.s	.ok
	move.l	d0,(a3,d2.w)
	bsr	bg_draw
.ok	addq.w	#1,d4
	dbf	d7,.col
	rts

blit_setup:
	bsr	blit_wait
	clr.w	BLTCON1(a6)
	move.l	#-1,BLTAFWM(a6)
	clr.w	BLTAMOD(a6)
	move.w	#LINEB-2,BLTDMOD(a6)
	rts

blit_wait:
	btst	#6,DMACONR(a6)
.w	btst	#6,DMACONR(a6)
	bne.s	.w
	rts

; draw cell: d0 = key, d2 = shadow offset, d4 = column, d5 = slot.
; Column C also covers the memory of column C-24 one slot down and C+24 one
; slot up: forget those if the shadow says they are there.
bg_draw:
	movem.l	d0-d7/a0/a2-a3,-(sp)
	lea	bgshadow(pc),a3
	move.w	d5,d1
	addq.w	#1,d1
	and.w	#15,d1
	mulu.w	#NCOLSLOT*4,d1
	add.w	d2,d1
	move.b	1(a3,d1.w),d3		; column held one slot down
	move.w	d4,d6
	sub.w	#NCOLSLOT,d6
	cmp.b	d6,d3
	bne.s	.n1
	move.l	#-1,(a3,d1.w)
.n1	move.w	d5,d1
	subq.w	#1,d1
	and.w	#15,d1
	mulu.w	#NCOLSLOT*4,d1
	add.w	d2,d1
	move.b	1(a3,d1.w),d3		; column held one slot up
	move.w	d4,d6
	add.w	#NCOLSLOT,d6
	cmp.b	d6,d3
	bne.s	.n2
	move.l	#-1,(a3,d1.w)
.n2	lea	bitmap+16(pc),a0
	move.w	d5,d1
	mulu.w	#16*LINEB,d1
	add.l	d1,a0
	add.w	d4,a0
	add.w	d4,a0			; + column * 2
	bsr	draw_tile		; d0.w = tile word
	movem.l	(sp)+,d0-d7/a0/a2-a3
	rts

colpart:	ds.l	256		; see init_display

; d0.w = code byte << 8 | attribute, a0 = destination (plane 0)
; attribute: bit 7 x flip, bits 6-3 colour, bits 2-0 code bits 8-10
draw_tile:
	movem.l	d0-d4/a0/a2/a3,-(sp)
	move.l	a0,d4
	moveq	#0,d1
	move.b	d0,d1			; attribute
	lsr.w	#8,d0
	moveq	#7,d2
	and.b	d1,d2
	lsl.w	#8,d2
	or.w	d2,d0			; tile number
	and.l	#$7ff,d0
	lsl.l	#7,d0
	lea	bgtiles(pc),a2
	add.l	d0,a2
	tst.b	d1
	bpl.s	.noflip
	bsr	blit_wait		; the blitter may still read the last flipped tile
	lea	fliptile(pc),a3
	lea	rev_table(pc),a0
	moveq	#63,d2
.fl	moveq	#0,d0
	move.b	(a2)+,d0
	move.b	(a0,d0.w),d3
	move.b	(a2)+,d0
	move.b	(a0,d0.w),(a3)+
	move.b	d3,(a3)+
	dbf	d2,.fl
	lea	fliptile(pc),a2
	move.l	d4,a0
.noflip	moveq	#3,d2			; pen planes 0-3 from the tile
.p	bsr	blit_wait
	move.w	#$09f0,BLTCON0(a6)
	move.l	a2,BLTAPT(a6)
	move.l	a0,BLTDPT(a6)
	move.w	#(16<<6)|1,BLTSIZE(a6)
	lea	32(a2),a2
	add.l	#PLANEALLOC,a0
	dbf	d2,.p
	lsr.b	#3,d1			; colour: planes 4-7 all 0 or all 1
	moveq	#3,d2
.k	bsr	blit_wait
	move.w	#$0100,d3
	lsr.b	#1,d1
	bcc.s	.z
	move.w	#$01ff,d3
.z	move.w	d3,BLTCON0(a6)
	move.l	a0,BLTDPT(a6)
	move.w	#(16<<6)|1,BLTSIZE(a6)
	add.l	#PLANEALLOC,a0
	dbf	d2,.k
	movem.l	(sp)+,d0-d4/a0/a2/a3
	rts

;------------------------------------------------------------------------------
; copper list for the next frame
COPMOVE	macro
	move.l	#((\1)<<16)|((\2)&$ffff),(a0)+
	endm

; palette RAM changed? (background 0-255 and text $300-$37F, compared with
; the shadow 4 bytes at a time) -> recompute those colours
	Z80	ZDB00,$db00
	Z80	ZDF00,$df00
	Z80	ZDBFC,$dbfc
	Z80	ZDFFC,$dffc
update_palette:
	lea	palshadow(pc),a3
	moveq	#0,d2			; anything changed?
	lea	(ZD800,a5),a0		; background, low bytes
	moveq	#64-1,d1
	bsr.s	.cmp
	lea	(ZDC00,a5),a0		; background, high bytes
	moveq	#64-1,d1
	bsr.s	.cmp
	lea	(ZDB00,a5),a0		; text, low bytes
	moveq	#32-1,d1
	bsr.s	.cmp
	lea	(ZDF00,a5),a0		; text, high bytes
	moveq	#32-1,d1
	bsr.s	.cmp
	lea	(ZDBFC,a5),a0		; backdrop (entry 1023), low and high
	moveq	#0,d1
	bsr.s	.cmp
	lea	(ZDFFC,a5),a0
	moveq	#0,d1
	bsr.s	.cmp
	tst.w	d2
	bne.s	.recalc
	rts
.cmp	cmpm.l	(a0)+,(a3)+
	beq.s	.n
	move.l	-4(a0),-4(a3)
	moveq	#1,d2
.n	dbf	d1,.cmp
	rts
.recalc	lea	pv_rgb(a4),a2
	moveq	#0,d3
.bg	move.w	d3,d0
	moveq	#15,d1
	and.w	d3,d1
	cmp.w	#15,d1			; pen 15 is transparent on the arcade: backdrop
	bne.s	.pen
	move.w	#$3ff,d0
.pen	bsr	pal_rgb
	move.w	d0,(a2)+
	addq.w	#1,d3
	cmp.w	#256,d3
	bne.s	.bg
	lea	pv_txrgb(a4),a2
	move.w	#$300,d3
.tx	move.w	d3,d0
	bsr	pal_rgb
	move.w	d0,(a2)+
	addq.w	#1,d3
	cmp.w	#$380,d3
	bne.s	.tx
	move.w	#2,pv_paldirty(a4)	; both copper lists
	rts

; d0 = palette RAM index -> d0.w = $0RGB
pal_rgb:
	move.w	d1,-(sp)
	moveq	#0,d1
	move.b	(ZDC00,a5,d0.w),d1	; xxxxBBBB
	and.w	#$0f,d1
	move.b	(ZD800,a5,d0.w),d0	; RRRRGGGG
	and.w	#$ff,d0
	lsl.w	#4,d0
	or.w	d1,d0
	move.w	(sp)+,d1
	rts

build_copper:
	lea	pvars(pc),a4
	lea	z80mem+$8000(pc),a5
	move.w	pv_copidx(a4),d0
	eor.w	#4,d0
	move.w	d0,pv_copidx(a4)
	lea	coplist0(pc),a0
	tst.w	d0
	beq.s	.l0
	lea	coplist1(pc),a0
.l0	lea	coplist_ptr(pc),a2
	move.l	a0,(a2)

	; palette section (fixed size, at the start): rewritten only when stale
	tst.w	pv_paldirty(a4)
	beq.s	.palok
	subq.w	#1,pv_paldirty(a4)
	lea	pv_rgb(a4),a2
	moveq	#0,d4
.bank	move.w	#BPLCON3,(a0)+
	move.w	d4,d1
	ror.w	#3,d1
	or.w	#$0040,d1		; lowres sprites
	move.w	d1,(a0)+
	move.w	#COLOR00,d1
	moveq	#31,d5
.col	move.w	d1,(a0)+
	move.w	(a2)+,(a0)+
	addq.w	#2,d1
	dbf	d5,.col
	addq.w	#1,d4
	cmp.w	#8,d4
	bne.s	.bank			; leaves BPLCON3 at bank 7 for the text colours
	bra.s	.paldone
.palok	lea	PALSECT(a0),a0
.paldone
	COPMOVE	FMODE,$000d		; 32-bit bitplane, 64-bit sprite fetch
	move.w	#BPLCON0,(a0)+
	move.w	#$0211,d1		; 8 planes
	btst	#1,pv_io+$c(a4)
	beq.s	.bgon
	move.w	#$0201,d1		; background disabled
.bgon	move.w	d1,(a0)+
	move.w	pv_vx(a4),d1		; fine scroll, as in src/viewer.s
	add.w	#31,d1
	and.w	#31,d1
	neg.w	d1
	add.w	#31,d1
	move.w	d1,d2
	and.w	#15,d2
	move.w	d2,d3
	lsl.w	#4,d3
	or.w	d3,d2
	lsr.w	#4,d1
	move.w	d1,d3
	lsl.w	#4,d3
	or.w	d3,d1
	lsl.w	#8,d1
	lsl.w	#2,d1
	or.w	d1,d2
	move.w	#BPLCON1,(a0)+
	move.w	d2,(a0)+
	COPMOVE	BPLCON2,$0024		; sprites in front
	COPMOVE	BPLCON4,$00ff		; sprite colours from 240-255
	COPMOVE	DIWSTRT,$3ca1
	COPMOVE	DIWSTOP,$1ca1
	COPMOVE	DDFSTRT,$0038
	COPMOVE	DDFSTOP,$00b8
	COPMOVE	BPL1MOD,MODULO
	COPMOVE	BPL2MOD,MODULO

	; bitplane pointers
	move.w	pv_vy(a4),d1
	and.w	#255,d1
	move.w	d1,d6			; buffer line at the top of the view
	mulu.w	#LINEB,d1
	moveq	#0,d2
	move.w	pv_vx(a4),d2
	add.w	#31,d2
	lsr.w	#5,d2
	lsl.w	#2,d2
	subq.l	#4,d2
	add.l	d2,d1
	lea	bitmap+16(pc),a3
	add.l	a3,d1
	move.w	#BPL1PTH,d3
	moveq	#NPLANES-1,d7
.ptr	move.w	d3,(a0)+
	swap	d1
	move.w	d1,(a0)+
	addq.w	#2,d3
	move.w	d3,(a0)+
	swap	d1
	move.w	d1,(a0)+
	addq.w	#2,d3
	add.l	#PLANEALLOC,d1
	dbf	d7,.ptr

	; sprite pointers: 0,2,4,6 text (if enabled), the rest empty
	move.w	#SPR0PTH,d3
	moveq	#0,d7
.spr	lea	nullspr(pc),a3
	move.l	a3,d1
	btst	#0,d7
	bne.s	.sset
	btst	#7,pv_io+4(a4)		; characters off?
	bne.s	.sset
	move.w	d7,d1
	lsr.w	#1,d1
	mulu.w	#TXSPR_SIZE,d1
	lea	txspr(pc),a3
	add.l	a3,d1
.sset	move.w	d3,(a0)+
	swap	d1
	move.w	d1,(a0)+
	addq.w	#2,d3
	move.w	d3,(a0)+
	swap	d1
	move.w	d1,(a0)+
	addq.w	#2,d3
	addq.w	#1,d7
	cmp.w	#8,d7
	bne.s	.spr

	; per character row: text colours, merged with the buffer wrap: the modulo
	; jumps back on line wset and is restored on line wrest
	move.w	#BUFH-1,d6
	sub.w	pv_vy(a4),d6
	and.w	#255,d6			; display offset of buffer line 255
	move.w	#$7fff,d1
	cmp.w	#VIEW_H-1,d6
	bhs.s	.nowrap
	add.w	#DISP_Y0,d6
	lea	cop_wset(pc),a3
	move.w	d6,(a3)
	addq.w	#1,d6
	move.w	d6,2(a3)		; cop_wrest
	bra.s	.w0
.nowrap	lea	cop_wset(pc),a3
	move.w	d1,(a3)
	move.w	d1,2(a3)
.w0	moveq	#0,d4			; not past line 255 yet
	moveq	#0,d5			; text row
.trow	move.w	d5,d3
	lsl.w	#3,d3
	add.w	#DISP_Y0,d3		; first line of text row d5
	move.w	cop_wset(pc),d0
	cmp.w	d3,d0
	bhs.s	.a
	bsr	cop_wait
	bsr	cop_modset
.a	move.w	cop_wrest(pc),d0
	cmp.w	d3,d0
	bhs.s	.b
	bsr	cop_wait
	bsr	cop_modrest
.b	move.w	d3,d0
	bsr	cop_wait
	cmp.w	cop_wset(pc),d3
	bne.s	.c
	bsr	cop_modset
.c	cmp.w	cop_wrest(pc),d3
	bne.s	.d
	bsr	cop_modrest
.d	lea	pv_rowpal(a4),a2	; colours 241-243, 245-247, 249-251, 253-255
	move.w	d5,d0
	lsl.w	#2,d0
	add.w	d0,a2
	move.w	#COLOR00+17*2,d2
	moveq	#3,d7
.sp4	moveq	#0,d0
	move.b	(a2)+,d0
	lsl.w	#3,d0			; 4 colours x 2 bytes
	lea	pv_txrgb(a4,d0.w),a3
	move.w	d2,(a0)+
	move.w	(a3)+,(a0)+
	addq.w	#2,d2
	move.w	d2,(a0)+
	move.w	(a3)+,(a0)+
	addq.w	#2,d2
	move.w	d2,(a0)+
	move.w	(a3)+,(a0)+
	addq.w	#4,d2
	dbf	d7,.sp4
	addq.w	#1,d5
	cmp.w	#TXROWS,d5
	bne	.trow
	move.w	cop_wset(pc),d0
	cmp.w	#$7fff,d0
	beq.s	.e
	bsr	cop_wait
	bsr	cop_modset
.e	move.w	cop_wrest(pc),d0
	cmp.w	#$7fff,d0
	beq.s	.f
	bsr	cop_wait
	bsr	cop_modrest
.f	move.l	#$fffffffe,(a0)+
	rts

cop_modset:
	COPMOVE	BPL1MOD,WRAPMOD
	COPMOVE	BPL2MOD,WRAPMOD
	lea	cop_wset(pc),a3
	move.w	#$7fff,(a3)
	rts

cop_modrest:
	COPMOVE	BPL1MOD,MODULO
	COPMOVE	BPL2MOD,MODULO
	lea	cop_wrest(pc),a3
	move.w	#$7fff,(a3)
	rts

; wait for display line d0 at the left edge (handles the line 255 crossing via d4)
cop_wait:
	cmp.w	#256,d0
	blo.s	.lo
	tst.w	d4
	bne.s	.lo
	move.l	#$ffdffffe,(a0)+
	moveq	#1,d4
.lo	move.w	d0,d1
	lsl.w	#8,d1
	or.w	#$07,d1
	move.w	d1,(a0)+
	move.w	#$fffe,(a0)+
	rts

cop_wset:	dc.w	0
cop_wrest:	dc.w	0
coplist_ptr:		dc.l	0

;------------------------------------------------------------------------------
	cnop	0,4
pvars:		ds.b	pv_size
		ds.b	2048
plat_stack_top:
rev_table:	ds.b	256

	include	"game.s"

	cnop	0,8
z80rom:		incbin	"z80fixed.bin"
z80banks:	incbin	"z80banks.bin"
bgtiles:	incbin	"bgtiles.bin"
chars:		incbin	"chars.bin"
charblank:	incbin	"charblank.bin"

; BSS: allocated (cleared) by the bootblock right after the loaded file
	cnop	0,8
bss_start:
bitmap		equ	bss_start+16
coplist0	equ	bitmap+PLANEALLOC*NPLANES
coplist1	equ	coplist0+COPSIZE
txspr		equ	coplist1+COPSIZE
nullspr		equ	txspr+4*TXSPR_SIZE
fliptile	equ	nullspr+32
z80mem		equ	fliptile+128
bgram		equ	z80mem+65536
task_stacks	equ	bgram+16384
bgshadow	equ	task_stacks+16*1024
txshadow	equ	bgshadow+16*NCOLSLOT*4
palshadow	equ	txshadow+2048		; 776 bytes
bss_end		equ	palshadow+776
