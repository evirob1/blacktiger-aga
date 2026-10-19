; Black Tiger AGA - level viewer
;
; Milestone 1 of the port: shows a level map converted from the arcade ROMs on
; an AGA 8-bitplane (256 colour) screen with smooth scrolling in both directions.
;
; Joystick in port 2 scrolls (fire = fast). With no input it pans by itself.
;
; Screen buffer: 8 separate planes, each MAP_W*16 pixels wide and 256 lines
; high (32K per plane). The whole map width is in the buffer, so only new tile
; rows ever need drawing. Vertically the buffer wraps: the copper changes the
; bitplane modulo for one line so every plane pointer jumps back to the top.

	machine	68020
	include	"level.i"

CUSTOM		equ	$dff000
DMACONR		equ	$002
VPOSR		equ	$004
JOY1DAT		equ	$00c
BLTCON0		equ	$040
BLTCON1		equ	$042
BLTAFWM		equ	$044
BLTALWM		equ	$046
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
COLOR00		equ	$180
FMODE		equ	$1fc
CIAA_PRA	equ	$bfe001

VIEW_W		equ	256
VIEW_H		equ	224
NPLANES		equ	8
LINEB		equ	MAP_W*2			; bytes per plane line
BUFH		equ	256			; buffer lines (16 tile rows)
PLANESZ		equ	LINEB*BUFH		; must be <= 32768 for the modulo wrap
FETCHB		equ	48			; 6 x 64 pixel blocks fetched per line (FMODE=3)
MODULO		equ	LINEB-FETCHB
WRAPMOD		equ	MODULO-PLANESZ
DISP_Y0		equ	$3c			; first displayed line
MAX_X		equ	MAP_W*16-VIEW_W
MAX_Y		equ	MAP_H*16-VIEW_H
COPSIZE		equ	256
IDLE_FRAMES	equ	100

	if	PLANESZ>32768
	fail	"map too wide for the modulo wrap"
	endif

; variables (A5 relative)
		rsreset
v_bitmap	rs.l	1
v_cop		rs.l	2
v_copidx	rs.w	1
v_x		rs.w	1
v_y		rs.w	1
v_dx		rs.w	1
v_dy		rs.w	1
v_idle		rs.w	1
v_row0		rs.w	1			; first map row held in the buffer
v_size		rs.b	0

start:
	lea	CUSTOM,a6
	move.w	#$7fff,INTENA(a6)
	move.w	#$7fff,INTREQ(a6)
	move.w	#$7fff,DMACON(a6)

	lea	vars(pc),a5
	lea	bss_start(pc),a0
	move.l	a0,d0
	add.l	#15+8,d0			; 8 bytes slack before the bitmap
	and.b	#$f8,d0				; 64-bit aligned for FMODE=3
	move.l	d0,v_bitmap(a5)
	add.l	#PLANESZ*NPLANES,d0
	move.l	d0,v_cop(a5)
	add.l	#COPSIZE,d0
	move.l	d0,v_cop+4(a5)
	clr.w	v_copidx(a5)
	ifd	TEST_X				; fixed view for automated screenshot tests
	move.w	#TEST_X,v_x(a5)
	move.w	#TEST_Y,v_y(a5)
	else
	clr.w	v_x(a5)
	clr.w	v_y(a5)
	endif
	move.w	#1,v_dx(a5)
	move.w	#1,v_dy(a5)
	move.w	#IDLE_FRAMES,v_idle(a5)

	bsr	load_palette

	move.w	#$8240,DMACON(a6)		; DMAEN|BLTEN for the initial fill
	bsr	blit_setup
	move.w	v_y(a5),d0
	lsr.w	#4,d0
	move.w	d0,v_row0(a5)
	moveq	#15,d7
.fill	movem.l	d0/d7,-(sp)
	bsr	draw_row
	movem.l	(sp)+,d0/d7
	addq.w	#1,d0
	dbf	d7,.fill

	bsr	build_copper
	move.w	#$87c0,DMACON(a6)		; + BPLEN|COPEN|BLTPRI

mainloop:
	bsr	wait_vbl
	ifnd	TEST_X
	bsr	move_view
	endif
	bsr	update_rows
	bsr	build_copper
	bra.s	mainloop

;------------------------------------------------------------------------------
wait_vbl:
.w1	move.l	VPOSR(a6),d0
	and.l	#$1ff00,d0
	cmp.l	#$12c00,d0
	bne.s	.w1
.w2	move.l	VPOSR(a6),d0
	and.l	#$1ff00,d0
	cmp.l	#$12c00,d0
	beq.s	.w2
	rts

;------------------------------------------------------------------------------
; joystick in port 2, or automatic panning when idle
move_view:
	move.w	JOY1DAT(a6),d0
	moveq	#0,d1				; dx
	moveq	#0,d2				; dy
	btst	#1,d0
	beq.s	.nr
	moveq	#2,d1
.nr	btst	#9,d0
	beq.s	.nl
	moveq	#-2,d1
.nl	move.w	d0,d3
	lsr.w	#1,d3
	eor.w	d0,d3
	btst	#0,d3
	beq.s	.nd
	moveq	#2,d2
.nd	btst	#8,d3
	beq.s	.nu
	moveq	#-2,d2
.nu	move.w	d1,d3
	or.w	d2,d3
	beq.s	.auto
	move.w	#IDLE_FRAMES,v_idle(a5)
	btst	#7,CIAA_PRA
	bne.s	.apply
	asl.w	#2,d1
	asl.w	#2,d2
	bra.s	.apply
.auto	tst.w	v_idle(a5)
	beq.s	.pan
	subq.w	#1,v_idle(a5)
	rts
.pan	move.w	v_dx(a5),d1
	move.w	v_dy(a5),d2
.apply	move.w	v_x(a5),d0
	add.w	d1,d0
	bpl.s	.x0
	moveq	#0,d0
	move.w	#1,v_dx(a5)
.x0	cmp.w	#MAX_X,d0
	ble.s	.x1
	move.w	#MAX_X,d0
	move.w	#-1,v_dx(a5)
.x1	move.w	d0,v_x(a5)
	move.w	v_y(a5),d0
	add.w	d2,d0
	bpl.s	.y0
	moveq	#0,d0
	move.w	#2,v_dy(a5)
.y0	cmp.w	#MAX_Y,d0
	ble.s	.y1
	move.w	#MAX_Y,d0
	move.w	#-2,v_dy(a5)
.y1	move.w	d0,v_y(a5)
	rts

;------------------------------------------------------------------------------
; make sure every tile row touched by the view is in the buffer
update_rows:
	move.w	v_y(a5),d4
	lsr.w	#4,d4				; top row needed
	move.w	v_y(a5),d5
	add.w	#VIEW_H-1,d5
	lsr.w	#4,d5				; bottom row needed
.up	move.w	v_row0(a5),d0
	cmp.w	d4,d0
	ble.s	.down
	subq.w	#1,d0
	move.w	d0,v_row0(a5)
	bsr	draw_row
	bra.s	.up
.down	move.w	v_row0(a5),d0
	add.w	#15,d0
	cmp.w	d5,d0
	bge.s	.done
	addq.w	#1,d0
	addq.w	#1,v_row0(a5)
	bsr	draw_row
	bra.s	.down
.done	rts

;------------------------------------------------------------------------------
blit_setup:
	bsr	blit_wait
	move.w	#$09f0,BLTCON0(a6)		; A -> D
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

; d0.w = map row -> buffer slot (row & 15)
draw_row:
	move.w	d0,d1
	mulu.w	#MAP_W*2,d1
	lea	map(pc),a0
	add.l	d1,a0				; map row
	moveq	#15,d1
	and.w	d0,d1
	mulu.w	#16*LINEB,d1
	move.l	v_bitmap(a5),a1
	add.l	d1,a1				; destination, plane 0, column 0
	lea	tiles(pc),a2
	moveq	#MAP_W-1,d7
.col	moveq	#0,d2
	move.w	(a0)+,d2
	lsl.l	#8,d2				; 256 bytes per tile
	lea	(a2,d2.l),a3
	move.l	a1,a4
	moveq	#NPLANES-1,d6
.plane	bsr.s	blit_wait
	move.l	a3,BLTAPT(a6)
	move.l	a4,BLTDPT(a6)
	move.w	#(16<<6)|1,BLTSIZE(a6)
	lea	32(a3),a3
	add.l	#PLANESZ,a4
	dbf	d6,.plane
	addq.l	#2,a1
	dbf	d7,.col
	rts

;------------------------------------------------------------------------------
; copper list for the next frame (double buffered)
build_copper:
	move.w	v_copidx(a5),d0
	eor.w	#4,d0
	move.w	d0,v_copidx(a5)
	move.l	v_cop(a5,d0.w),a0
	move.l	a0,-(sp)

	move.l	#(FMODE<<16)|3,(a0)+
	move.l	#(BPLCON0<<16)|$0211,(a0)+	; 8 planes, ECSENA
	; FMODE=3 fetches in 64 pixel blocks (DDFSTRT snaps to $18,$38,..). With
	; DDFSTRT $18 the first fetched pixel is 96 pixels left of the window edge
	; (DIW $a1), which leaves room for the full 0-63 pixel delay
	move.w	v_x(a5),d1
	add.w	#31,d1
	and.w	#63,d1
	neg.w	d1
	add.w	#63,d1				; delay = 63 - ((x+31) & 63)
	move.w	d1,d2
	and.w	#15,d2
	move.w	d2,d3
	lsl.w	#4,d3
	or.w	d3,d2				; PF1H5-2 / PF2H5-2
	lsr.w	#4,d1
	move.w	d1,d3
	lsl.w	#4,d3
	or.w	d3,d1
	lsl.w	#8,d1
	lsl.w	#2,d1				; PF1H7-6 bits 11-10, PF2H7-6 bits 15-14
	or.w	d1,d2
	move.w	#BPLCON1,(a0)+
	move.w	d2,(a0)+
	move.l	#(BPLCON2<<16)|$0000,(a0)+
	move.l	#(BPLCON3<<16)|$0000,(a0)+
	move.l	#(BPLCON4<<16)|$0000,(a0)+
	move.l	#(DIWSTRT<<16)|$3ca1,(a0)+
	move.l	#(DIWSTOP<<16)|$1ca1,(a0)+
	move.l	#(DDFSTRT<<16)|$0018,(a0)+
	move.l	#(DDFSTOP<<16)|$00b8,(a0)+
	move.l	#(BPL1MOD<<16)|(MODULO&$ffff),(a0)+
	move.l	#(BPL2MOD<<16)|(MODULO&$ffff),(a0)+

	; plane pointers: buffer line (y & 255), byte column ((x+31)/64)*8-8
	move.w	v_y(a5),d1
	and.w	#255,d1
	move.w	d1,d4				; keep ytop
	mulu.w	#LINEB,d1
	moveq	#0,d2
	move.w	v_x(a5),d2
	add.w	#31,d2
	lsr.w	#6,d2
	lsl.w	#3,d2
	subq.l	#8,d2
	add.l	d2,d1
	add.l	v_bitmap(a5),d1
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
	add.l	#PLANESZ,d1
	dbf	d7,.ptr

	; buffer wrap: the line showing buffer line 255 gets a modulo that jumps
	; every pointer back to buffer line 0
	move.w	#BUFH-1,d1
	sub.w	d4,d1				; display offset of buffer line 255
	cmp.w	#VIEW_H-1,d1
	bge.s	.nowrap
	add.w	#DISP_Y0,d1			; display line
	cmp.w	#256,d1
	blt.s	.w1
	move.l	#$ffdffffe,(a0)+
.w1	move.w	d1,d2
	lsl.w	#8,d2
	or.w	#$07,d2
	move.w	d2,(a0)+
	move.w	#$fffe,(a0)+
	move.l	#(BPL1MOD<<16)|(WRAPMOD&$ffff),(a0)+
	move.l	#(BPL2MOD<<16)|(WRAPMOD&$ffff),(a0)+
	addq.w	#1,d1
	cmp.w	#256,d1
	bne.s	.w2
	move.l	#$ffdffffe,(a0)+
.w2	move.w	d1,d2
	lsl.w	#8,d2
	or.w	#$07,d2
	move.w	d2,(a0)+
	move.w	#$fffe,(a0)+
	move.l	#(BPL1MOD<<16)|(MODULO&$ffff),(a0)+
	move.l	#(BPL2MOD<<16)|(MODULO&$ffff),(a0)+
.nowrap	move.l	#$fffffffe,(a0)+

	move.l	(sp)+,d0
	move.l	d0,COP1LC(a6)			; taken at the next vertical blank
	rts

;------------------------------------------------------------------------------
; 256 colours from level.pal ($00RRGGBB), via the AGA bank/LOCT mechanism
load_palette:
	lea	palette(pc),a0
	moveq	#0,d7
.bank	move.w	d7,d0
	ror.w	#3,d0				; bank number -> bits 15-13
	move.w	d0,BPLCON3(a6)
	lea	COLOR00(a6),a1
	move.l	a0,a2
	moveq	#31,d6
.hi	move.l	(a2)+,d1
	move.l	d1,d2
	lsr.l	#8,d2
	lsr.l	#4,d2
	and.w	#$f00,d2
	move.l	d1,d3
	lsr.l	#8,d3
	and.w	#$0f0,d3
	or.w	d3,d2
	move.w	d1,d3
	lsr.w	#4,d3
	and.w	#$00f,d3
	or.w	d3,d2
	move.w	d2,(a1)+
	dbf	d6,.hi
	or.w	#$0200,d0			; LOCT
	move.w	d0,BPLCON3(a6)
	lea	COLOR00(a6),a1
	moveq	#31,d6
.lo	move.l	(a0)+,d1
	move.l	d1,d2
	lsr.l	#8,d2
	and.w	#$f00,d2
	move.w	d1,d3
	lsr.w	#4,d3
	and.w	#$0f0,d3
	or.w	d3,d2
	move.w	d1,d3
	and.w	#$00f,d3
	or.w	d3,d2
	move.w	d2,(a1)+
	dbf	d6,.lo
	addq.w	#1,d7
	cmp.w	#8,d7
	bne.s	.bank
	clr.w	BPLCON3(a6)
	rts

;------------------------------------------------------------------------------
	cnop	0,4
vars:		ds.b	v_size
	cnop	0,4
palette:	incbin	"level.pal"
map:		incbin	"level.map"
	cnop	0,8
tiles:		incbin	"level.tiles"
	cnop	0,8
bss_start:
