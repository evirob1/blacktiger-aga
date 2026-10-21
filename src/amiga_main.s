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
;  * display, rebuilt from the arcade video RAM, triple buffered, by a second
;    context that runs whenever the game is idle (its scheduler finds no task
;    to run) - the game always comes first, the display drops frames if it
;    has to:
;      background  8 bitplanes, tiles drawn from background RAM, hardware scroll;
;                  both map layouts (64 x 128 and 128 x 64 tiles)
;      sprites     blitter objects drawn over the background (the background
;                  under them is saved first and put back two frames later)
;    60 Hz (NTSC timing, as the arcade) unless built with -DPAL (50 Hz)
;      text layer  8 hardware sprites 64 pixels wide, 2 bitplanes like the
;                  arcade characters: per 64 pixels of a character row, two
;                  palettes (even sprite, odd sprite), set by the copper
;      palette     16 colour slots of 16 (one AGA colour bank each): the arcade
;                  palettes on screen (background 0-15, sprites 16-23) get a
;                  slot each, slots 14 and 15 are the text layer's
;    Not yet: background priority (tiles in front of sprites), sound.
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
BLTALWM		equ	$046
BLTCPT		equ	$048
BLTBPT		equ	$04c
BLTAPT		equ	$050
BLTDPT		equ	$054
BLTSIZE		equ	$058
BLTCMOD		equ	$060
BLTBMOD		equ	$062
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
COLOR01		equ	$182
BEAMCON0	equ	$1dc
FMODE		equ	$1fc
CIAA_PRA	equ	$bfe001
CIAA_SDR	equ	$bfec01
CIAA_ICR	equ	$bfed01
CIAA_CRA	equ	$bfee01

; Background buffer: 24 tile columns (48 bytes) x 256 lines per plane, wrapping
; in both directions. Vertically the copper changes the modulo for one line;
; horizontally the bitplane pointer simply moves on: memory column M is drawn
; at byte 2*M of its tile row, so it shares memory with column M-24 one line
; further down, which is never on screen at the same time (17 columns are).
; Memory column M shows map column M-16 (mod the map width): the view can
; start up to 256 pixels left of the map's left edge, where the arcade wraps.
VIEW_H		equ	224
NPLANES		equ	8
LINEB		equ	48
BUFH		equ	256
PLANESZ		equ	LINEB*BUFH
PLANEALLOC	equ	16+PLANESZ+320+64	; slack before, map width after
FETCHB		equ	36			; 9 x 32 pixels (FMODE=1)
MODULO		equ	LINEB-FETCHB
WRAPMOD		equ	MODULO-PLANESZ
NCOLSLOT	equ	24
COLBIAS		equ	16			; memory column = map column + 16
	ifd	PAL
DISP_Y0		equ	$3c			; 50 Hz: 313 lines
	else
DISP_Y0		equ	$24			; 60 Hz (NTSC timing, as the arcade): 262 lines
	endif
COPSIZE		equ	5120			; (about 4.1K used)
PALSECT		equ	8*(1+32)*4		; palette section at the start of each copper list
TXROWS		equ	28			; arcade text rows 2-29 are visible
TXSPR_SIZE	equ	16+VIEW_H*16+16		; 64-bit sprite: control, lines, end
SPR_H0		equ	$a0			; sprite x of the left window edge
NSLOTS		equ	14			; colour slots for the bitplanes (14, 15: text)
NSPR		equ	128			; arcade sprites
REC_SIZE	equ	20			; one blitter object (or the part of one
					; above / below the buffer's line wrap):
REC_DEST	equ	0			; l  destination, plane 0
REC_H		equ	4			; w  lines
REC_SHIFT	equ	6			; w  shift << 12
REC_MASK	equ	8			; l  mask (16 words)
REC_DATA	equ	12			; l  planes 0-3 (16 words each)
REC_SLOT	equ	16			; w  colour slot
SAVESIZE	equ	27*1024			; background saved under the sprites, per buffer
SAVE_ROW	equ	NPLANES*4		; ... per line of a sprite
NBUF		equ	3			; display buffers: shown, queued, being drawn
MAXBOB		equ	64			; sprites drawn per frame at most
BMSIZE		equ	PLANEALLOC*NPLANES
SHSIZE		equ	16*NCOLSLOT*4		; background shadow per buffer
RECSIZE		equ	2*MAXBOB*REC_SIZE
BS_GEN		equ	0			; l  pv_bggen at the buffer's last scan
BS_INV		equ	4			; w  pv_invgen then
BS_R0		equ	6			; w  view: first / last map row, column (not wrapped)
BS_R1		equ	8
BS_C0		equ	10
BS_C1		equ	12
BS_LAY		equ	14			; w  layout
BS_OFF		equ	16			; b  background off
BS_MASK		equ	18			; 16 x w  palettes in each buffer slot row
BS_SIZE		equ	50

; platform variables (a4 relative inside the display code)
		rsreset
pv_io		rs.b	16			; last value written to each I/O port
pv_iod		rs.b	16			; the copy the display is drawing
pv_slot_of	rs.b	24			; palette -> colour slot, -1: none
pv_pal_of	rs.b	16			; colour slot -> palette, -1: none
pv_nrec		rs.w	NBUF			; blitter objects drawn in each buffer
pv_in0		rs.b	1			; port 0 value (active low)
pv_in1		rs.b	1			; port 1 value (active low)
pv_indisp	rs.b	1			; the display context is running
pv_dwork	rs.b	1			; display: a new game frame to draw
		rs.b	1
pv_bgoff	rs.b	1			; background disabled (port $0C)
pv_drawn	rs.w	1			; frames drawn (for tools/harness/amiga_sim)
pv_textver	rs.w	1			; text colours version (rows / palette)
pv_csig		rs.l	NBUF			; per copper list: wrap line << 16 | pv_textver
pv_shown	rs.w	1			; buffer on screen
pv_queued	rs.w	1			; buffer on screen from the next vblank (-1: none)
pv_qdelay	rs.w	1			; ... from the one after that
pv_txhalf	rs.w	1			; text rows checked this frame: 0, 7, 14, 21
pv_palhalf	rs.b	1			; palette half checked this frame
		rs.b	1
pv_chgend	rs.l	1			; end of chglist
pv_bggen	rs.l	1			; background RAM write generation (bg_mark)
pv_scangen	rs.l	1			; ... as seen by the scan in progress
pv_invgen	rs.w	1			; shadows invalidated (forget_pal / forget_all)
pv_full		rs.b	1			; scan in progress looks at every cell
		rs.b	1
pv_srow		rs.w	1			; map row being scanned (wrapped)
pv_saverows	rs.w	1			; sprite lines planned this frame
pv_bobcut	rs.w	1			; first sprite number left out (bob_cutoff)
pv_palcnt	rs.b	32			; draw_row: characters per text palette
pv_cheat	rs.b	1			; test mode (Help key): no damage, lives, time
pv_helpkey	rs.b	1			; Help key held last frame
pv_clives	rs.b	1			; test mode: lives kept at least at this
pv_level	rs.b	1			; F1-F8: start the next game at level 1-8 (0: as usual)
pv_f9key	rs.b	1			; F9 held last frame
		rs.b	1
pv_ctime	rs.w	1			; time (minutes << 8 | seconds, BCD)
pv_ctick	rs.w	1			; frames since the time last changed
pv_usedacc	rs.l	1			; background palettes on screen
pv_bstate	rs.b	(NBUF+1)*BS_SIZE	; per buffer (+ clean): what its last scan saw
pv_layout	rs.w	1			; 0: 64 x 128 tiles, 1: 128 x 64 (port $0E)
pv_cmask	rs.w	1			; map width in tiles - 1
pv_vx		rs.w	1			; view position in the map (pixels, signed)
pv_vy		rs.w	1
pv_back		rs.w	1			; buffer being drawn (0 / 1)
pv_bm		rs.l	1			; its bitmap (plane 0)
pv_sh		rs.l	1			; its background shadow
pv_rec		rs.l	1			; its blitter objects
pv_save		rs.l	1			; the background saved under them
pv_used		rs.l	1			; palettes on screen this frame
pv_overload	rs.w	1			; slots borrowed (count, for amiga_sim)
pv_borrowed	rs.b	1			; the last get_slot borrowed a slot
pv_dbusy	rs.b	1			; the display is in the middle of a frame
pv_starve	rs.w	1			; vblanks since the display finished a frame
pv_paldirty	rs.w	1			; copper lists whose palette section is stale (bit per buffer)
pv_rowpal	rs.b	TXROWS*8		; text palette per row and sprite
pv_rgb		rs.w	256			; background colours, 12 bit (pen 15: backdrop)
pv_sprgb	rs.w	128			; sprite colours (follows pv_rgb: palettes 16-23)
pv_txrgb	rs.w	128			; text colours (palette entries $300-$37F)
pv_blank	rs.w	16			; unused slot: black, pen 15 backdrop
pv_keys		rs.b	128
pv_sprbuf	rs.b	4*NSPR			; sprite RAM, buffered on out ($06)
pv_sprsnap	rs.b	4*NSPR			; the copy being drawn
pv_size		rs.b	0

;------------------------------------------------------------------------------
start:
	lea	super(pc),a5
	jsr	-30(a6)			; Exec Supervisor(): continue in supervisor mode
super:
	move.w	#$2700,sr
	lea	snd_a6(pc),a0		; a2 (bootblock): the sound program's ROM and
	move.l	a2,(a0)			; the bank, at its memory's $8000 (src/sound.s),
	lea	snd_on(pc),a0		; or 0: no room for sound
	move.l	a2,d0
	sne	(a0)
	lea	snd_nomusic(pc),a0	; no fast RAM: sound effects only (F9: music
	move.l	a3,d0			; too)
	seq	(a0)
	lea	chipa(pc),a0		; a3 (bootblock): separate chip RAM block, or 0
	move.l	a3,d0
	bne.s	.fast
	lea	z80rom(pc),a1
	move.l	a1,(a0)
	lea	bss_end(pc),a1
	move.l	a1,4(a0)
	bra.s	.mem
.fast	move.l	d0,(a0)
	lea	clean_on(pc),a1		; (the clean background: room for it)
	st	(a1)
	add.l	#(CHIPA_FAST+7)&-8,d0
	move.l	d0,4(a0)
.mem	lea	plat_stack_top(pc),sp
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
	bclr	#1,CIAA_PRA		; the audio filter on (the power LED bright)
	move.b	#$7f,CIAA_ICR		; keyboard: CIA-A serial port interrupt only
	tst.b	CIAA_ICR
	move.b	#$88,CIAA_ICR
	and.b	#$bf,CIAA_CRA
	move.w	#$ff00,POTGO(a6)	; second fire button readable on POTINP
	ifnd	PAL
	clr.w	BEAMCON0(a6)		; NTSC timing: 60 frames a second, as the arcade
	endif

	bsr	unpack_data
	bsr	init_display
	move.w	#$87e0,DMACON(a6)	; bitplanes, copper, blitter (nasty), sprites
	move.w	#$c028,INTENA(a6)	; vertical blank + keyboard
	tst.b	snd_on(pc)
	beq.s	.quiet
	bsr	snd_init		; the sound board: its program's start-up,
	move.l	chipb(pc),a0		; then the player (audio interrupt, level 4)
	add.l	#CB_AUDIO,a0
	bsr	play_init
.quiet
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

CHIPA	macro				; \2 = chip area A + \1
	move.l	chipa(pc),\2
	add.l	#\1,\2
	endm

CHIPB	macro				; \2 = chip area B + \1
	move.l	chipb(pc),\2
	add.l	#\1,\2
	endm

BOUNDARY macro
	endm

PLAT_IDLE macro				; let the display run until the next vblank
	bsr	disp_run
	endm

PLAT_DI	macro				; (68k) interrupts off
	ori.w	#$0700,sr
	endm

PLAT_HIT macro				; test mode: a hit does no damage (c)
	tst.b	(pvars+pv_cheat,pc)
	beq.s	.nohit\@
	clr.b	d1
.nohit\@
	endm

PLAT_LEVEL macro			; a game starts ($1E77, about to read the
	tst.b	(pvars+pv_level,pc)	; level for where the player starts): the
	beq.s	.nolevel\@		; level chosen with F1-F8, for this game,
	move.l	a0,-(sp)		; both players (their records, $F3C0 /
	lea	pvars+pv_level(pc),a0	; $F3E0, are copied to $F3A0 each turn)
	move.b	(a0),d7			; (flags: none live here)
	clr.b	(a0)
	subq.b	#1,d7
	move.b	d7,(ZF3A1,a6)
	move.b	d7,(ZF3C1,a6)
	move.b	d7,(ZF3E1,a6)
	move.l	(sp)+,a0
.nolevel\@
	endm

PLAT_EI	macro				; enable + deliver a vblank that came while disabled
	bsr	z80_ei
	endm

ROM_PRELOADED	equ	1		; (unpack_data copies the fixed ROM)
	include	"rt_core.s"
SND_ROM_IN_PLACE equ	1		; (unpacked there: unpack_data)
	include	"snd_bank.i"		; (tools/sound/bank.py)

SNDLOG	macro				; (the sound program's YM writes: for tests)
	endm
	include	"sound.s"		; the sound board's program, translated
	include	"sound_play.s"		; and its chips' registers made into sound

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

; d7 = port, d0 = value. out ($06) buffers sprite RAM ($FE00-$FFFF) for the display.
	Z80	ZFE00,$fe00
plat_out:
	move.l	a0,-(sp)
	lea	pvars(pc),a0
	move.b	d0,pv_io(a0,d7.w)
	tst.w	d7
	bne.s	.n0
	tst.b	snd_nomusic(pc)		; port 0: a command for the sound board
	beq.s	.cmd			; (music off: its commands, $21-$37, left
	cmp.b	#$21,d0			; out)
	blo.s	.cmd
	cmp.b	#$37,d0
	bls.s	.x
.cmd	lea	snd_latch(pc),a0
	move.b	d0,(a0)
	bra.s	.x
.n0	cmp.w	#4,d7
	bne.s	.n4
	tst.b	snd_on(pc)
	beq.s	.x
	move.w	sr,-(sp)		; port 4 bit 5: the sound CPU's reset (its
	ori.w	#$0700,sr		; start-up when released runs in one piece)
	bsr	snd_reset
	move.w	(sp)+,sr
	bra.s	.x
.n4	cmp.w	#6,d7
	bne.s	.x
	movem.l	d0/a2,-(sp)
	move.w	sr,-(sp)		; in one piece (the display may run at a vblank)
	ori.w	#$0700,sr
	lea	(ZFE00,a6),a2
	lea	pv_sprbuf(a0),a0
	moveq	#NSPR-1,d0
.c	move.l	(a2)+,(a0)+
	dbf	d0,.c
	move.w	(sp)+,sr
	movem.l	(sp)+,d0/a2
.x	move.l	(sp)+,a0
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

; something jumped to Z80 code that was never translated: stop with a red
; screen that says where (d7 = bank << 16 | address), in the arcade's font
z80_bad_jump:
	move.w	#$2700,sr
	lea	CUSTOM,a6
	move.w	#$7fff,DMACON(a6)
	move.l	d7,d6
	CHIPA	CA_SAVE0,a0		; one bitplane, 320 x 256
	move.w	#40*256/4-1,d0
.cl	clr.l	(a0)+
	dbf	d0,.cl
	lea	bad_where+5(pc),a0	; "BANK xx AT xxxx"
	move.l	d6,d0
	swap	d0
	moveq	#2-1,d1
	ror.w	#8,d0
	bsr	.hex
	lea	bad_where+11(pc),a0
	move.w	d6,d0
	moveq	#4-1,d1
	bsr	.hex
	lea	bad_from+5(pc),a0	; "FROM bb aaaa": the jp (hl) that went there
	move.l	rt_vars+RT_JPFROM(pc),d6
	move.l	d6,d0
	swap	d0
	moveq	#2-1,d1
	ror.w	#8,d0
	bsr	.hex
	lea	bad_from+8(pc),a0
	move.w	d6,d0
	moveq	#4-1,d1
	bsr	.hex
	lea	bad_from(pc),a2
	CHIPA	CA_SAVE0+40*160+6,a3
	bsr	bad_text
	lea	bad_title(pc),a2
	CHIPA	CA_SAVE0+40*96+4,a3
	bsr	bad_text
	lea	bad_where(pc),a2
	CHIPA	CA_SAVE0+40*128+6,a3
	bsr	bad_text
	move.w	#$1200,BPLCON0(a6)	; plain lowres, 1 plane
	clr.w	BPLCON1(a6)
	clr.w	BPLCON2(a6)
	clr.w	BPLCON3(a6)
	clr.w	FMODE(a6)
	move.w	#$2c81,DIWSTRT(a6)
	move.w	#$2cc1,DIWSTOP(a6)
	move.w	#$0038,DDFSTRT(a6)
	move.w	#$00d0,DDFSTOP(a6)
	clr.w	BPL1MOD(a6)
	move.w	#$0b00,COLOR00(a6)
	move.w	#$0fff,COLOR01(a6)
	move.w	#$8300,DMACON(a6)	; bitplanes only; the CPU sets the pointer
	CHIPA	CA_SAVE0,a0
.fr	move.l	VPOSR(a6),d0
	and.l	#$1ff00,d0
	cmp.l	#$00200,d0
	bne.s	.fr
	move.l	a0,BPL1PTH(a6)
.fr2	move.l	VPOSR(a6),d0
	and.l	#$1ff00,d0
	cmp.l	#$00200,d0
	beq.s	.fr2
	bra.s	.fr
; d0 = value (top digit in bits 15-12), d1 = digits - 1 -> ASCII at (a0)
.hex	rol.w	#4,d0
	moveq	#15,d2
	and.w	d0,d2
	move.b	.dig(pc,d2.w),(a0)+
	dbf	d1,.hex
	rts
.dig	dc.b	"0123456789ABCDEF"

; text a2 (0-terminated) at a3, characters doubled to 16 x 16
bad_text:
.c	moveq	#0,d0
	move.b	(a2)+,d0
	beq.s	.x
	lsl.w	#4,d0
	lea	chars(pc),a0
	add.w	d0,a0			; 8 x (plane A, plane B)
	move.l	a3,a1
	moveq	#7,d3
.l	move.b	(a0)+,d0
	and.b	(a0)+,d0		; any pen but the transparent one (3)
	not.b	d0
	moveq	#0,d1
	moveq	#7,d2
.b	add.b	d0,d0			; each pixel twice
	scs	d4
	add.w	d1,d1
	add.w	d1,d1
	and.w	#3,d4
	or.w	d4,d1
	dbf	d2,.b
	move.w	d1,(a1)
	move.w	d1,40(a1)
	lea	80(a1),a1
	dbf	d3,.l
	addq.l	#2,a3
	bra.s	.c
.x	rts

bad_title:	dc.b	"UNKNOWN Z80 CODE",0
bad_where:	dc.b	"BANK xx AT xxxx",0
bad_from:	dc.b	"FROM xx xxxx",0
	even

plat_irq:				; (rt_core header; the Amiga uses lev3)
	rte

;------------------------------------------------------------------------------
; Two contexts share the CPU: the game, and the display (disp_main), which
; runs only while the game is idle. A context not running is parked on its
; own stack as d0-a6 + an exception frame (ctx_g / ctx_d point at it).

; level 3: vertical blank -> inputs, then the Z80 interrupt, in the game's
; context (if the display was running, it is parked)
lev3:
	btst	#5,CUSTOM+INTREQR+1
	beq.s	.other
	move.w	#$0020,CUSTOM+INTREQ
	move.w	#$0020,CUSTOM+INTREQ
	movem.l	d0-d7/a0-a6,-(sp)
	lea	pvars(pc),a4
	tst.b	pv_indisp(a4)
	beq.s	.game
	lea	ctx_d(pc),a0
	move.l	sp,(a0)
	sf	pv_indisp(a4)
	move.l	ctx_g(pc),sp
.game	movem.l	(sp),d0-d7/a0-a6	; the game's registers (a1: ROM bank pointer)
	bsr	vblank_quick
	lea	rt_vars(pc),a4
	tst.b	RT_IE(a4)
	beq.s	.pend
	bsr	rt_irq_body
	bra.s	.done
.pend	st	RT_PENDING(a4)
.done	move.l	a1,9*4(sp)		; (the interrupt may switch the ROM bank)
	lea	pvars(pc),a4		; no frame drawn for 3 vblanks (the game uses all
	cmp.w	#3,pv_starve(a4)	; the time): the display goes first now, the game
	blo.s	.ret			; slows down instead (as the arcade does)
	tst.b	pv_dwork(a4)
	bne.s	.disp
	tst.b	pv_dbusy(a4)
	beq.s	.ret
.disp	lea	ctx_g(pc),a0
	move.l	sp,(a0)
	st	pv_indisp(a4)
	move.l	ctx_d(pc),sp
.ret	movem.l	(sp)+,d0-d7/a0-a6
	rte
.other	move.w	#$0050,CUSTOM+INTREQ	; copper / blitter
	rte

; the game is idle: run the display (if it has a frame to draw) until it is
; done or the next vblank. Keeps all registers.
disp_run:
	move.l	a0,-(sp)
	lea	pvars(pc),a0
	tst.b	pv_dwork(a0)
	movem.l	(sp)+,a0		; (keeps the flags)
	beq.s	.x
	move.w	#$006c,-(sp)		; exception frame: format 0, level 3 vector
	pea	.x(pc)
	move.w	sr,-(sp)
	movem.l	d0-d7/a0-a6,-(sp)
	move.w	#$2700,sr
	lea	ctx_g(pc),a0
	move.l	sp,(a0)
	lea	pvars(pc),a0
	st	pv_indisp(a0)
	move.l	ctx_d(pc),sp
	movem.l	(sp)+,d0-d7/a0-a6
	rte
.x	rts

; the display context: one frame per round, then back to the game
disp_main:
	bsr	draw_frame
	move.w	#$006c,-(sp)
	pea	disp_main(pc)
	move.w	#$2000,-(sp)
	movem.l	d0-d7/a0-a6,-(sp)
	move.w	#$2700,sr
	lea	ctx_d(pc),a0
	move.l	sp,(a0)
	lea	pvars(pc),a0
	sf	pv_indisp(a0)
	move.l	ctx_g(pc),sp
	movem.l	(sp)+,d0-d7/a0-a6
	rte

ctx_g:	dc.l	0
ctx_d:	dc.l	0

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
; boot: unpack the graphics and banked ROM (tools/lzpack.py format), make the
; sprite masks, clear the display buffers (they reuse the packed data's space)
unpack_data:
	lea	z80rom(pc),a0		; fixed ROM -> Z80 $0000-$7FFF (its space is
	lea	z80mem+$8000(pc),a1	; reused below)
	move.w	#$8000/4-1,d7
.rom	move.l	(a0)+,(a1)+
	dbf	d7,.rom
	lea	lz_banks(pc),a0
	lea	z80banks(pc),a1
	bsr	lz_unpack
	lea	lz_tiles(pc),a0
	CHIPB	CB_BGTILES,a1
	bsr	lz_unpack
	lea	lz_chars(pc),a0
	lea	chars(pc),a1
	bsr	lz_unpack
	lea	lz_sprites(pc),a0
	CHIPB	CB_SPRITES,a1
	bsr	lz_unpack
	CHIPB	CB_SPRITES,a0		; mask: 1 where any pen but 15 (transparent)
	CHIPB	CB_SPRMASK,a1
	move.w	#2048-1,d7
.sm	moveq	#15,d6
.sl	move.w	(a0),d0
	and.w	32(a0),d0
	and.w	64(a0),d0
	and.w	96(a0),d0
	not.w	d0
	move.w	d0,(a1)+
	addq.l	#2,a0
	dbf	d6,.sl
	lea	128-32(a0),a0
	dbf	d7,.sm
	CHIPB	CB_SPRMASK,a0		; rows with pixels: first << 8 | count
	lea	sprrows(pc),a1
	move.w	#2048-1,d7
.sr	moveq	#-1,d0			; first
	moveq	#0,d1			; last + 1
	moveq	#0,d2
.r	tst.w	(a0)+
	beq.s	.e
	tst.w	d0
	bpl.s	.f
	move.w	d2,d0
.f	move.w	d2,d1
	addq.w	#1,d1
.e	addq.w	#1,d2
	cmp.w	#16,d2
	bne.s	.r
	moveq	#0,d2
	tst.w	d0
	bmi.s	.st			; empty
	sub.w	d0,d1
	move.b	d0,d2
	lsl.w	#8,d2
	move.b	d1,d2
.st	move.w	d2,(a1)+
	dbf	d7,.sr
	CHIPA	0,a0			; display buffers: cleared
	move.l	#CHIPA_SIZE/4,d0
	tst.b	clean_on(pc)
	beq.s	.cl
	move.l	#CHIPA_FAST/4,d0
.cl	clr.l	(a0)+
	subq.l	#1,d0
	bne.s	.cl
	rts

; a0 = packed, a1 = destination
lz_unpack:
.tok	moveq	#0,d0
	move.b	(a0)+,d0
	bmi.s	.match
.lit	move.b	(a0)+,(a1)+		; $00-$7F: t+1 literal bytes
	dbf	d0,.lit
	bra.s	.tok
.match	cmp.b	#$ff,d0
	beq.s	.end
	and.w	#$7f,d0			; $80-$FE: (t & $7F) + 3 bytes from distance
	addq.w	#2,d0
	moveq	#0,d1
	move.b	(a0)+,d1
	lsl.w	#8,d1
	move.b	(a0)+,d1
	move.l	a1,a2
	sub.l	d1,a2
.cp	move.b	(a2)+,(a1)+
	dbf	d0,.cp
	bra.s	.tok
.end	rts

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
	; text sprites: control words, 64 pixels wide, VIEW_H lines from DISP_Y0;
	; sprites 2n and 2n+1 cover the same 64 pixels
	CHIPA	CA_TXSPR,a0
	moveq	#0,d7
.sp	move.w	#DISP_Y0,d0
	move.w	#DISP_Y0+VIEW_H,d1
	move.w	d7,d2
	lsr.w	#1,d2
	lsl.w	#6,d2
	add.w	#SPR_H0,d2
	bsr	sprite_ctl
	lea	TXSPR_SIZE(a0),a0
	addq.w	#1,d7
	cmp.w	#8,d7
	bne.s	.sp
	clr.w	pv_vx(a4)
	clr.w	pv_vy(a4)
	move.w	#-1,pv_layout(a4)	; forces a full redraw
	lea	colpart(pc),a0		; per map column: byte offset in its row
	moveq	#0,d0
.cp	move.w	d0,d1
	and.w	#15,d1
	move.w	d0,d2
	and.w	#$30,d2
	lsl.w	#4,d2
	add.w	d2,d1
	add.w	d1,d1
	move.w	d1,(a0)			; layout 0
	move.w	d0,d1
	and.w	#15,d1
	move.w	d0,d2
	and.w	#$70,d2
	lsl.w	#4,d2
	add.w	d2,d1
	add.w	d1,d1
	move.w	d1,256(a0)		; layout 1
	addq.l	#2,a0
	addq.w	#1,d0
	cmp.w	#128,d0
	bne.s	.cp
	lea	mshoff(pc),a0		; per memory column: shadow offset (M mod 24) * 4
	moveq	#0,d0
.ms	moveq	#0,d1
	move.w	d0,d1
	divu.w	#NCOLSLOT,d1
	swap	d1
	lsl.w	#2,d1
	move.w	d1,(a0)+
	addq.w	#1,d0
	cmp.w	#160,d0
	bne.s	.ms
	lea	pv_bstate(a4),a0	; no scans yet: the first ones look at every cell
	moveq	#NBUF,d0
.bs	move.w	#-1,BS_INV(a0)
	lea	BS_SIZE(a0),a0
	dbf	d0,.bs
	lea	fliptag(pc),a0		; flip cache empty
	moveq	#64-1,d0
.ft	move.l	#$ffff0000,(a0)+
	dbf	d0,.ft
	lea	pv_slot_of(a4),a0	; no colour slots given out
	moveq	#24+16-1,d0
.ns	st	(a0)+
	dbf	d0,.ns
	moveq	#-1,d0
	move.b	d0,pv_in0(a4)
	move.b	d0,pv_in1(a4)
	lea	disp_stack_top(pc),a0	; the display context, parked at its start
	move.w	#$006c,-(a0)
	lea	disp_main(pc),a1
	move.l	a1,-(a0)
	move.w	#$2000,-(a0)
	lea	-15*4(a0),a0
	lea	ctx_d(pc),a1
	move.l	a0,(a1)
	moveq	#-1,d0
	move.l	d0,pv_csig(a4)		; copper lists not built yet
	move.l	d0,pv_csig+4(a4)
	move.l	d0,pv_csig+8(a4)
	move.w	d0,pv_queued(a4)
	clr.w	pv_shown(a4)
	clr.w	pv_back(a4)		; buffer 0 on screen first
	bsr	set_buffer
	move.w	#(1<<NBUF)-1,pv_paldirty(a4)
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

; pv_back -> the buffer's bitmap, shadow, object list and save area
set_buffer:
	move.l	d0,-(sp)
	moveq	#0,d0
	move.w	pv_back(a4),d0
	mulu.w	#SHSIZE,d0
	lea	bgshadow0(pc),a0
	add.l	d0,a0
	move.l	a0,pv_sh(a4)
	cmp.w	#NBUF,pv_back(a4)	; NBUF: the clean background (no objects)
	bne.s	.disp
	CHIPA	CA_CLEAN,a0
	move.l	a0,pv_bm(a4)
	move.l	(sp)+,d0
	rts
.disp	moveq	#0,d0
	move.w	pv_back(a4),d0
	mulu.l	#BMSIZE,d0
	CHIPA	CA_BITMAP0,a0
	add.l	d0,a0
	move.l	a0,pv_bm(a4)
	move.w	pv_back(a4),d0
	mulu.w	#RECSIZE,d0
	lea	rec0(pc),a0
	add.l	d0,a0
	move.l	a0,pv_rec(a4)
	move.w	pv_back(a4),d0
	mulu.w	#SAVESIZE,d0
	CHIPA	CA_SAVE0,a0
	add.l	d0,a0
	move.l	a0,pv_save(a4)
	move.l	(sp)+,d0
	rts

;------------------------------------------------------------------------------
	Z80	ZD000,$d000
	Z80	ZD400,$d400
	Z80	ZD800,$d800
	Z80	ZDC00,$dc00

; in the vertical blank interrupt: inputs; the queued buffer is on screen
; from now; a new game frame for the display to draw
vblank_quick:
	lea	pvars(pc),a4
	lea	CUSTOM,a6
	bsr	read_inputs
	bsr	test_mode
	move.w	pv_queued(a4),d0
	bmi.s	.n
	tst.w	pv_qdelay(a4)
	beq.s	.sh
	clr.w	pv_qdelay(a4)
	bra.s	.n
.sh	move.w	d0,pv_shown(a4)
	move.w	#-1,pv_queued(a4)
.n	st	pv_dwork(a4)
	addq.w	#1,pv_starve(a4)
	rts

; one frame, into a buffer neither on screen nor queued; its copper list is
; shown from the next vblank (a queued frame not shown yet is dropped: this
; one is newer). Runs in the display context: the game can run in between
; (video RAM may change while it is read; the shadows record what was drawn)
draw_frame:
	lea	pvars(pc),a4
	lea	z80mem+$8000(pc),a5
	lea	CUSTOM,a6
	move.w	#$2700,sr		; sprite RAM as buffered by the game
	sf	pv_dwork(a4)
	st	pv_dbusy(a4)
	lea	pv_sprbuf(a4),a0	; with the I/O registers of the same moment
	lea	pv_sprsnap(a4),a2	; (scroll, layout, video enables)
	moveq	#NSPR-1,d0
.sn	move.l	(a0)+,(a2)+
	dbf	d0,.sn
	move.l	pv_io(a4),pv_iod(a4)
	move.l	pv_io+4(a4),pv_iod+4(a4)
	move.l	pv_io+8(a4),pv_iod+8(a4)
	move.l	pv_io+12(a4),pv_iod+12(a4)
	moveq	#0,d0			; a free buffer
.fb	cmp.w	pv_shown(a4),d0
	beq.s	.nf
	cmp.w	pv_queued(a4),d0
	bne.s	.fr
.nf	addq.w	#1,d0
	bra.s	.fb
.fr	move.w	d0,pv_back(a4)
	move.w	#$2000,sr
	bsr	set_buffer
	bsr	restore_bobs
	bsr	update_palette
	bsr	update_text
	tst.b	clean_on(pc)
	bne.s	.clean
	bsr	update_background
	bra.s	.bobs
.clean	move.w	pv_back(a4),-(sp)	; the clean background, then this buffer's
	move.w	#NBUF,pv_back(a4)	; cells made the same
	bsr	set_buffer
	bsr	update_background
	move.w	(sp)+,pv_back(a4)
	bsr	set_buffer
	bsr	sync_clean
.bobs	bsr	draw_bobs
	bsr	build_copper
	bsr	blit_wait
	move.w	#$2700,sr
	move.l	coplist_ptr(pc),COP1LC(a6)	; used from the next vblank
	move.w	pv_back(a4),pv_queued(a4)
	moveq	#0,d0
	btst	#5,INTREQR+1(a6)	; that one has begun already: the one after
	sne	d0
	move.w	d0,pv_qdelay(a4)
	sf	pv_dbusy(a4)
	clr.w	pv_starve(a4)
	move.w	#$2000,sr
	addq.w	#1,pv_drawn(a4)
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
; Test mode, toggled with the Help key (not shown: the power LED's bit is
; also the audio filter's, which stays on): the strongest weapon ($F3AC =
; 4); a potion always there ($F3B0), which a poison attack uses up instead;
; hits do no damage (PLAT_HIT, at the one place the game takes a hit off the
; armour, $F3AD: holding that value up instead fought the game's own changes
; to it), and lives and time never go down. Black Tiger's RAM:
	Z80	ZF3A0,$f3a0		; lives
	Z80	ZF3A1,$f3a1		; level (0-7)
	Z80	ZF3C1,$f3c1		; (player 1's record)
	Z80	ZF3E1,$f3e1		; (player 2's)
	Z80	ZF3AC,$f3ac		; weapon (0-4: what the shop sells)
	Z80	ZF3B0,$f3b0		; potions
	Z80	ZF3B1,$f3b1		; time: seconds, BCD
	Z80	ZF3B2,$f3b2		; minutes
test_mode:
	lea	z80mem+$8000(pc),a0
	tst.b	pv_keys+$58(a4)		; F9: music on / off (on press)
	sne	d0
	move.b	pv_f9key(a4),d1
	move.b	d0,pv_f9key(a4)
	not.b	d1
	and.b	d1,d0
	beq.s	.nf9
	lea	snd_nomusic(pc),a1
	not.b	(a1)
	beq.s	.nf9			; on: from the next tune the game starts
	tst.b	snd_on(pc)		; off: the sound CPU starts again, silent
	beq.s	.nf9
	move.w	sr,-(sp)
	ori.w	#$0700,sr
	bsr	snd_init
	move.w	(sp)+,sr
.nf9	moveq	#8-1,d0			; F1-F8: the level the next game starts at
.lk	tst.b	pv_keys+$50(a4,d0.w)	; (PLAT_LEVEL)
	beq.s	.lk2
	move.b	d0,pv_level(a4)
	addq.b	#1,pv_level(a4)
.lk2	dbf	d0,.lk
	tst.b	pv_keys+$5f(a4)		; Help: toggle on press
	sne	d0
	move.b	pv_helpkey(a4),d1
	move.b	d0,pv_helpkey(a4)
	not.b	d1
	and.b	d1,d0
	beq.s	.on
	not.b	pv_cheat(a4)
	move.b	(ZF3A0,a0),pv_clives(a4)	; from the values now
	move.b	(ZF3B2,a0),d0
	lsl.w	#8,d0
	move.b	(ZF3B1,a0),d0
	move.w	d0,pv_ctime(a4)
.on	tst.b	pv_cheat(a4)
	beq.s	.x
	cmp.b	#4,(ZF3AC,a0)		; the strongest weapon
	bhs.s	.wp
	move.b	#4,(ZF3AC,a0)
.wp	tst.b	(ZF3B0,a0)		; a potion: a poison attack uses it up
	bne.s	.pt			; instead ($4824)
	move.b	#1,(ZF3B0,a0)
.pt	move.b	(ZF3A0,a0),d0		; lives
	cmp.b	pv_clives(a4),d0
	bhs.s	.l2
	move.b	pv_clives(a4),(ZF3A0,a0)
	bra.s	.t
.l2	move.b	d0,pv_clives(a4)
.t	move.b	(ZF3B2,a0),d0		; time: the once a second tick is undone
	lsl.w	#8,d0			; (not the fast count into the bonus at the
	move.b	(ZF3B1,a0),d0		; end of a level)
	addq.w	#1,pv_ctick(a4)
	cmp.w	pv_ctime(a4),d0
	beq.s	.x
	bhi.s	.t2
	cmp.w	#30,pv_ctick(a4)
	blo.s	.t2
	move.b	pv_ctime(a4),(ZF3B2,a0)
	move.b	pv_ctime+1(a4),(ZF3B1,a0)
	clr.w	pv_ctick(a4)
	rts
.t2	move.w	d0,pv_ctime(a4)
	clr.w	pv_ctick(a4)
.x	rts

;------------------------------------------------------------------------------
; text layer: arcade rows 2-29 into the sprites. Rows are compared with the
; shadow copy 4 bytes at a time (a quarter of them each frame); a changed row is
; drawn again in full.
update_text:
	lea	txshadow(pc),a3
	move.w	pv_txhalf(a4),d5	; a quarter of the rows per frame
	move.w	d5,d4
	add.w	#TXROWS/4,d4
	cmp.w	#TXROWS,d4
	blo.s	.h
	moveq	#0,d4
.h	move.w	d4,pv_txhalf(a4)
	move.w	d5,d4
	add.w	#TXROWS/4,d4		; end
.row	move.w	d5,d0
	addq.w	#2,d0
	lsl.w	#5,d0			; first cell of the row
	lea	(ZD000,a5,d0.w),a0
	lea	(a3,d0.w),a2
	moveq	#7,d1
.cc	cmpm.l	(a0)+,(a2)+
	bne.s	.chg
	dbf	d1,.cc
	lea	(ZD400,a5,d0.w),a0
	lea	$400(a3,d0.w),a2
	moveq	#7,d1
.ca	cmpm.l	(a0)+,(a2)+
	bne.s	.chg
	dbf	d1,.ca
	bra.s	.same
.chg	lea	(ZD000,a5,d0.w),a0	; copy the row, then draw it from the copy
	lea	(a3,d0.w),a2
	moveq	#7,d1
.cp	move.l	$400(a0),$400(a2)
	move.l	(a0)+,(a2)+
	dbf	d1,.cp
	bsr	draw_row
.same	addq.w	#1,d5
	cmp.w	d4,d5
	bne.s	.row
	rts

; text row d5 from txshadow: per block of 8 characters, the most used palette
; goes to the even sprite, the next most used to the odd sprite (any further
; palette is shown with the first)
draw_row:
	movem.l	d0-d7/a0-a3,-(sp)
	addq.w	#1,pv_textver(a4)
	move.w	d5,d0
	addq.w	#2,d0
	lsl.w	#5,d0
	lea	txshadow(pc),a3
	add.w	d0,a3			; the row's codes, attributes at +$400
	lea	pv_rowpal(a4),a1
	move.w	d5,d0
	lsl.w	#3,d0
	add.w	d0,a1
	CHIPA	CA_TXSPR+16,a2		; block 0, even sprite, this row
	move.w	d5,d0
	lsl.w	#7,d0			; 8 lines x 16 bytes
	add.w	d0,a2
	moveq	#3,d7			; block
.blk	lea	pv_palcnt(a4),a0	; characters per palette in the block
	moveq	#7,d6
.cl	clr.l	(a0)+
	dbf	d6,.cl
	moveq	#7,d6
.fp	bsr	cell_char
	bmi.s	.fn			; (blank)
	moveq	#$1f,d1
	and.b	$400(a3),d1
	lea	pv_palcnt(a4),a0
	addq.b	#1,(a0,d1.w)
.fn	addq.l	#1,a3
	dbf	d6,.fp
	subq.l	#8,a3
	moveq	#-1,d3			; palettes A, B: the two most used
	moveq	#-1,d4
	moveq	#0,d5			; their counts
	moveq	#0,d2
	lea	pv_palcnt(a4),a0
	moveq	#31,d6
.pk	moveq	#0,d1
	move.b	(a0,d6.w),d1
	beq.s	.pn
	cmp.w	d5,d1
	bls.s	.pb
	move.w	d5,d2			; new first; the old one second
	move.w	d3,d4
	move.w	d1,d5
	move.w	d6,d3
	bra.s	.pn
.pb	cmp.w	d2,d1
	bls.s	.pn
	move.w	d1,d2
	move.w	d6,d4
.pn	dbf	d6,.pk
	move.b	d3,(a1)+		; ($ff: none)
	move.b	d4,(a1)+
	moveq	#7,d6
.dc	bsr	cell_char		; a0 = character
	moveq	#0,d2			; drawn into: the even sprite
	move.l	#TXSPR_SIZE,d5		; cleared: the odd one
	moveq	#$1f,d1
	and.b	$400(a3),d1
	cmp.w	d4,d1
	bne.s	.ev
	exg	d2,d5			; palette B: the other way round
.ev	moveq	#7,d1
.ln	move.b	(a0)+,(a2,d2.l)
	move.b	(a0)+,8(a2,d2.l)
	clr.b	(a2,d5.l)
	clr.b	8(a2,d5.l)
	lea	16(a2),a2
	dbf	d1,.ln
	lea	1-8*16(a2),a2		; next column
	addq.l	#1,a3
	dbf	d6,.dc
	lea	2*TXSPR_SIZE-8(a2),a2	; next block
	dbf	d7,.blk
	movem.l	(sp)+,d0-d7/a0-a3
	rts

; (a3) = code, $400(a3) = attribute -> a0 = character data; N set if it is
; blank. Uses d0-d1.
cell_char:
	moveq	#0,d0
	move.b	$400(a3),d0
	and.w	#$e0,d0
	lsl.w	#3,d0
	move.b	(a3),d0			; character number
	lea	charblank(pc),a0
	move.b	(a0,d0.w),d1
	lea	chars(pc),a0
	lsl.l	#4,d0
	add.l	d0,a0
	neg.b	d1
	rts

;------------------------------------------------------------------------------
; colour slots. Slot s is AGA colours 16s-16s+15; a pixel's planes 4-7 hold
; its slot. A palette keeps its slot while it is in use; one that needs a slot
; takes a free one, or one whose palette isn't on screen this frame (the cells
; drawn with that palette, in both buffers, are then drawn again when seen).

; d0.w = palette (0-15 background, 16-23 sprites) -> d0.w = its slot
get_slot:
	movem.l	d1-d3/a0,-(sp)
	move.l	pv_used(a4),d3
	bset	d0,d3
	move.l	d3,pv_used(a4)
	moveq	#0,d1
	move.b	pv_slot_of(a4,d0.w),d1
	bpl.s	.have
	lea	pv_pal_of(a4),a0
	moveq	#NSLOTS-1,d1
.free	tst.b	(a0,d1.w)
	bmi.s	.take
	dbf	d1,.free
	moveq	#NSLOTS-1,d1
.idle	moveq	#0,d2
	move.b	(a0,d1.w),d2
	btst	d2,d3
	beq.s	.evict
	dbf	d1,.idle
	; more palettes on screen than slots: borrow a slot of the same kind
	; (background / sprite) for this frame, without taking it away
	addq.w	#1,pv_overload(a4)
	st	pv_borrowed(a4)
	moveq	#NSLOTS-1,d1
.bw	move.b	(a0,d1.w),d2
	eor.b	d0,d2
	and.b	#$10,d2			; same kind?
	beq.s	.have
	dbf	d1,.bw
	moveq	#0,d1
	bra.s	.have
.evict	moveq	#0,d2
	move.b	(a0,d1.w),d2
	st	pv_slot_of(a4,d2.w)
	cmp.w	#16,d2
	bhs.s	.take
	bsr	forget_pal
.take	move.b	d0,(a0,d1.w)
	move.b	d1,pv_slot_of(a4,d0.w)
	move.w	#(1<<NBUF)-1,pv_paldirty(a4)
.have	move.w	d1,d0
	movem.l	(sp)+,d1-d3/a0
	rts

; d2 = background palette: forget the cells drawn with it in all buffers
forget_pal:
	movem.l	d0-d1/a0,-(sp)
	addq.w	#1,pv_invgen(a4)
	lea	bgshadow0(pc),a0
	move.w	#(NBUF+1)*16*NCOLSLOT-1,d1
.l	move.l	(a0)+,d0
	lsr.w	#3,d0
	and.w	#15,d0
	cmp.w	d2,d0
	bne.s	.n
	move.l	#-1,-4(a0)
.n	dbf	d1,.l
	movem.l	(sp)+,d0-d1/a0
	rts

forget_all:
	addq.w	#1,pv_invgen(a4)
	lea	bgshadow0(pc),a0
	move.w	#(NBUF+1)*16*NCOLSLOT-1,d1
.l	move.l	#-1,(a0)+
	dbf	d1,.l
	rts

;------------------------------------------------------------------------------
; background: every visible cell is compared with what its buffer slot holds
; (map row, memory column, tile word); anything different is drawn. That
; covers scrolling in any direction, changed tiles and layout switches alike.
update_background:
	moveq	#1,d0
	and.b	pv_iod+$e(a4),d0		; layout
	cmp.w	pv_layout(a4),d0
	beq.s	.same
	move.w	d0,pv_layout(a4)
	bsr	forget_all		; new layout: nothing in the buffers is valid
	move.w	pv_layout(a4),d0
.same	move.w	#1024,d2		; map width in pixels
	move.w	#2048,d3		; and height
	moveq	#63,d1
	tst.w	d0
	beq.s	.l0
	exg	d2,d3
	moveq	#127,d1
.l0	move.w	d1,pv_cmask(a4)
	moveq	#0,d0
	move.b	pv_iod+9(a4),d0
	lsl.w	#8,d0
	move.b	pv_iod+8(a4),d0
	move.w	d2,d1
	subq.w	#1,d1
	and.w	d1,d0
	move.w	d2,d1
	sub.w	#256,d1
	cmp.w	d1,d0
	bls.s	.xok
	sub.w	d2,d0			; view across the left edge: negative
.xok	move.w	d0,pv_vx(a4)
	moveq	#0,d0
	move.b	pv_iod+$b(a4),d0
	lsl.w	#8,d0
	move.b	pv_iod+$a(a4),d0
	add.w	#16,d0			; arcade visible area starts at line 16
	subq.w	#1,d3
	and.w	d3,d0
	move.w	d0,pv_vy(a4)

	moveq	#2,d0
	and.b	pv_iod+$c(a4),d0
	sne	pv_bgoff(a4)		; background off: blank cells
	lea	chglist(pc),a0
	move.l	a0,pv_chgend(a4)
	bsr	scan_tiles
	bsr	mark_sprites
	bsr	blit_setup
	lea	chglist(pc),a2		; draw the cells that changed
.c	cmp.l	pv_chgend(a4),a2
	bhs.s	.x
	move.l	(a2)+,d0		; key
	move.w	(a2)+,d2		; shadow offset in the row
	move.w	(a2)+,d4		; memory column
	move.w	(a2)+,d5		; buffer slot
	move.l	pv_sh(a4),a3
	move.w	d5,d1
	mulu.w	#NCOLSLOT*4,d1
	add.w	d2,d1
	move.l	d0,(a3,d1.w)
	bsr	bg_draw
	bra.s	.c
.x	rts

; -> d6 = first visible map row (not wrapped), d7 = rows - 1
view_rows:
	move.w	pv_vy(a4),d6
	lsr.w	#4,d6
	move.w	pv_vy(a4),d7
	add.w	#VIEW_H-1,d7
	lsr.w	#4,d7
	sub.w	d6,d7
	rts

; -> d4 = first visible map column (signed, not wrapped), d7 = columns - 1
view_cols:
	move.w	pv_vx(a4),d4
	asr.w	#4,d4
	move.w	pv_vx(a4),d7
	add.w	#255,d7
	asr.w	#4,d7
	sub.w	d4,d7
	rts

; every visible cell: its key (map row, memory column, tile word) against the
; shadow; the ones that differ go to chglist (key, shadow offset, memory
; column, buffer slot). Their palettes -> d5.
scan_tiles:
	move.w	pv_back(a4),d0		; a5: this buffer's scan state
	mulu.w	#BS_SIZE,d0
	lea	pv_bstate(a4),a5
	add.w	d0,a5
	move.l	pv_bggen(a4),pv_scangen(a4)
	clr.l	pv_usedacc(a4)
	move.w	pv_invgen(a4),d0	; look at every cell if the shadow was invalidated,
	cmp.w	BS_INV(a5),d0		; the layout changed or the background was switched
	sne	d1			; on or off
	move.w	pv_layout(a4),d0
	cmp.w	BS_LAY(a5),d0
	sne	d0
	or.b	d0,d1
	move.b	pv_bgoff(a4),d0
	cmp.b	BS_OFF(a5),d0
	sne	d0
	or.b	d0,d1
	move.b	d1,pv_full(a4)
	lea	chglist(pc),a6
	lea	colpart(pc),a0
	tst.w	pv_layout(a4)
	beq.s	.c0
	lea	256(a0),a0
.c0	move.w	pv_cmask(a4),d3
	bsr	view_rows
.row	movem.w	d6-d7,-(sp)
	moveq	#15,d0
	and.w	d6,d0
	move.w	d0,a1			; buffer slot
	mulu.w	#NCOLSLOT*4,d0
	move.l	pv_sh(a4),a3
	add.w	d0,a3			; shadow of the buffer slot
	bsr	row_off			; (d6 wrapped)
	move.w	d6,pv_srow(a4)
	lea	bgram(pc),a2		; (all four banks: the Z80 window isn't used)
	add.w	d0,a2
	bsr	view_cols		; d4 first column, d7 columns - 1
	moveq	#0,d5
	tst.b	pv_full(a4)
	bne	.all
	move.w	(sp),d6			; (row, not wrapped)
	cmp.w	BS_R0(a5),d6
	blt.s	.all			; the row wasn't on screen
	cmp.w	BS_R1(a5),d6
	bgt.s	.all
	move.w	d4,d1			; written since? (the visible columns lie in two
	and.w	d3,d1			; groups of 16 tiles of the row)
	move.w	(a0,d1.w*2),d1
	add.w	d0,d1
	lsr.w	#5,d1
	lea	grpgen(pc),a6
	move.l	(a6,d1.w*4),d1
	cmp.l	BS_GEN(a5),d1
	bhi.s	.alla6
	move.w	d4,d1
	add.w	d7,d1
	and.w	d3,d1
	move.w	(a0,d1.w*2),d1
	add.w	d0,d1
	lsr.w	#5,d1
	move.l	(a6,d1.w*4),d1
	cmp.l	BS_GEN(a5),d1
	bhi.s	.alla6
	move.l	pv_chgend(a4),a6	; (chglist pointer: kept in pv_chgend meanwhile)
	move.w	a1,d1			; the row is as it was: only the columns that
	add.w	d1,d1			; weren't on screen
	move.w	BS_MASK(a5,d1.w),d5
	move.w	d4,d6			; c0 .. min(c1, old c0 - 1)
	add.w	d7,d6			; d6 = c1
	move.w	d6,-(sp)
	move.w	BS_C0(a5),d1
	subq.w	#1,d1
	cmp.w	d6,d1
	bge.s	.p1
	move.w	d1,d6
.p1	sub.w	d4,d6			; count - 1
	bmi.s	.p2
	move.w	d4,-(sp)
	move.w	d6,d7
	bsr	scan_cols
	move.w	(sp)+,d4
.p2	move.w	(sp)+,d6		; c1
	move.w	BS_C1(a5),d1		; max(c0, old c1 + 1) .. c1
	addq.w	#1,d1
	cmp.w	d4,d1
	ble.s	.p3
	move.w	d1,d4
.p3	move.w	d6,d7
	sub.w	d4,d7
	bmi.s	.rdone
	bsr	scan_cols
	bra.s	.rdone
.alla6	move.l	pv_chgend(a4),a6
.all	bsr	scan_cols		; the whole row
.rdone	move.w	a1,d1
	add.w	d1,d1
	move.w	d5,BS_MASK(a5,d1.w)
	or.w	d5,pv_usedacc+2(a4)
	move.l	a6,pv_chgend(a4)
	movem.w	(sp)+,d6-d7
	addq.w	#1,d6
	dbf	d7,.row
	move.l	pv_scangen(a4),BS_GEN(a5)	; what this buffer shows now
	move.w	pv_invgen(a4),BS_INV(a5)
	bsr	view_rows
	move.w	d6,BS_R0(a5)
	add.w	d7,d6
	move.w	d6,BS_R1(a5)
	bsr	view_cols
	move.w	d4,BS_C0(a5)
	add.w	d7,d4
	move.w	d4,BS_C1(a5)
	move.w	pv_layout(a4),BS_LAY(a5)
	move.b	pv_bgoff(a4),BS_OFF(a5)
	move.l	pv_usedacc(a4),d5
	lea	CUSTOM,a6
	lea	z80mem+$8000(pc),a5
	rts

; cells d4 .. d4 + d7 of the row being scanned (columns not wrapped): key
; against the shadow, changes to chglist (a6), palettes -> d5. a0 colpart,
; a1 buffer slot, a2 the row's tile words, a3 its shadow, d3 column mask.
scan_cols:
	move.w	pv_srow(a4),d0		; key: row << 24 | memory column << 16 | tile
	lsl.w	#8,d0
	move.b	d4,d0
	add.b	#COLBIAS,d0
	swap	d0
	move.w	mshoff+2*COLBIAS(pc,d4.w*2),d2	; shadow offset, then stepped
	move.w	d4,d1
	and.w	d3,d1
	move.w	(a0,d1.w*2),d1		; tile offset in the row, then stepped
	tst.b	pv_bgoff(a4)
	bne.s	.off
.col	move.w	(a2,d1.w),d0		; tile word: code << 8 | attribute
	cmp.l	(a3,d2.w),d0
	bne.s	.chg
.mk	move.b	d0,d6			; palette in use
	lsr.b	#3,d6
	and.w	#15,d6
	bset	d6,d5
	add.l	#$10000,d0
	addq.w	#2,d1
	addq.w	#4,d2
	cmp.w	#NCOLSLOT*4,d2
	bne.s	.s1
	moveq	#0,d2
.s1	addq.w	#1,d4
	moveq	#15,d6			; next block of 16 columns: from the table
	and.w	d4,d6
	bne.s	.s2
	move.w	d4,d1
	and.w	d3,d1
	move.w	(a0,d1.w*2),d1
.s2	dbf	d7,.col
	rts
.chg	bsr.s	.add
	bra.s	.mk
.off	clr.w	d0			; background off: blank cells
	bset	#31,d0
.oc	cmp.l	(a3,d2.w),d0
	beq.s	.on
	bsr.s	.add
.on	add.l	#$10000,d0
	addq.w	#4,d2
	cmp.w	#NCOLSLOT*4,d2
	bne.s	.o1
	moveq	#0,d2
.o1	addq.w	#1,d4
	dbf	d7,.oc
	rts
.add	move.l	d0,(a6)+		; to chglist
	move.w	d2,(a6)+
	move.w	d4,d6
	add.w	#COLBIAS,d6
	move.w	d6,(a6)+		; memory column
	move.w	a1,(a6)+		; buffer slot
	rts

; Background RAM writes by the game (bg_stores.txt sites and block moves):
; the 32-byte group (16 tiles of one row) gets the next generation number,
; so the scans know what changed. d0.w = Z80 address; keeps all registers.
bg_mark_d2:
	move.l	d0,-(sp)
	move.w	d2,d0
	bra.s	bg_mark0
bg_mark_d3:
	move.l	d0,-(sp)
	move.w	d3,d0
bg_mark0:
	bsr.s	bg_mark
	move.l	(sp)+,d0
	rts
bg_mark:
	cmp.w	#$c000,d0
	blo.s	.x
	cmp.w	#$d000,d0
	bhs.s	.x
	movem.l	d0-d1/a0,-(sp)
	and.w	#$0fff,d0
	moveq	#3,d1
	and.b	rt_vars+RT_BGBANK(pc),d1
	lsl.w	#8,d1
	lsl.w	#4,d1
	or.w	d1,d0
	lsr.w	#5,d0			; group 0-511
	lea	pvars(pc),a0
	addq.l	#1,pv_bggen(a0)
	move.l	pv_bggen(a0),d1
	lea	grpgen(pc),a0
	move.l	d1,(a0,d0.w*4)
	movem.l	(sp)+,d0-d1/a0
.x	rts

; block move about to write d1 bytes from d2 up (ldir) / down (lddr)
bg_mark_up:
	movem.l	d0-d1,-(sp)
	move.w	d2,d0
	bra.s	bg_mark_blk
bg_mark_down:
	movem.l	d0-d1,-(sp)
	move.w	d2,d0
	sub.w	d1,d0
	addq.w	#1,d0			; lowest address
bg_mark_blk:
	subq.w	#1,d1
	add.w	d0,d1			; highest address
.l	bsr.s	bg_mark
	add.w	#32,d0
	bcs.s	.e
	cmp.w	d1,d0
	bls.s	.l
.e	move.w	d1,d0
	bsr.s	bg_mark
	movem.l	(sp)+,d0-d1
	rts

; sprite palettes on screen -> d5, then pv_used (before any slot is given out)
mark_sprites:
	btst	#2,pv_iod+$c(a4)		; sprites off?
	bne.s	.x
	lea	pv_sprsnap(a4),a0
	moveq	#NSPR-1,d7
.s	move.b	2(a0),d0		; y
	beq.s	.n
	cmp.b	#240,d0
	bhs.s	.n
	moveq	#0,d1
	move.b	1(a0),d1
	moveq	#0,d2
	move.b	3(a0),d2
	btst	#4,d1
	beq.s	.xp
	sub.w	#256,d2
.xp	cmp.w	#-15,d2
	blt.s	.n
	and.w	#7,d1
	add.w	#16,d1
	bset	d1,d5
.n	addq.l	#4,a0
	dbf	d7,.s
.x	move.l	d5,pv_used(a4)
	rts

; d6 = map row (not wrapped) -> d6 wrapped, d0 = its offset in the 16K. Uses d1.
row_off:
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

; draw cell: d0 = key, d2 = shadow offset, d4 = memory column, d5 = slot.
; Column M shares memory with every column M+24k, k lines up: drawing it
; covers the first k lines of M-24k one slot down and the last k of M+24k one
; slot up (k > 1 after a jump of the view, e.g. out of a shop): forget those
; if the shadow says they are there.
bg_draw:
	movem.l	d0-d7/a0/a2-a3,-(sp)
	move.l	pv_sh(a4),a3
	move.w	d5,d1
	addq.w	#1,d1
	and.w	#15,d1
	mulu.w	#NCOLSLOT*4,d1
	add.w	d2,d1
	move.b	1(a3,d1.w),d3		; column held one slot down: if left of
	cmp.b	d4,d3			; this one (M - 24k: its first k lines are
	bhs.s	.n1			; drawn over), forget it
	move.l	#-1,(a3,d1.w)
.n1	move.w	d5,d1
	subq.w	#1,d1
	and.w	#15,d1
	mulu.w	#NCOLSLOT*4,d1
	add.w	d2,d1
	move.b	1(a3,d1.w),d3		; column held one slot up: if right of
	cmp.b	d4,d3			; this one (M + 24k: its last k lines), or
	bls.s	.n2			; nothing (-1)
	move.l	#-1,(a3,d1.w)
.n2	move.l	pv_bm(a4),a0
	move.w	d5,d1
	mulu.w	#16*LINEB,d1
	add.l	d1,a0
	add.w	d4,a0
	add.w	d4,a0			; + column * 2
	sf	pv_borrowed(a4)
	bsr	draw_tile
	tst.b	pv_borrowed(a4)		; drawn with a borrowed slot: again next frame
	beq.s	.x
	move.w	d5,d1
	mulu.w	#NCOLSLOT*4,d1
	add.w	d2,d1
	move.l	#-1,(a3,d1.w)
	addq.w	#1,pv_invgen(a4)
.x
	movem.l	(sp)+,d0-d7/a0/a2-a3
	rts

colpart:	ds.w	256		; see init_display
chglist:	ds.b	15*17*10	; cells to draw (scan_tiles)
grpgen:		ds.l	512		; per 32 bytes of background RAM: generation of the last write
mshoff:		ds.w	160

; d0.l = key (bit 31: blank cell, else the low word is code byte << 8 |
; attribute), a0 = destination (plane 0)
; attribute: bit 7 x flip, bits 6-3 colour, bits 2-0 code bits 8-10
draw_tile:
	movem.l	d0-d4/a0/a2/a3,-(sp)
	move.l	a0,d4
	tst.l	d0
	bmi	.blank
	moveq	#0,d1
	move.b	d0,d1			; attribute
	lsr.w	#8,d0
	moveq	#7,d2
	and.b	d1,d2
	lsl.w	#8,d2
	or.w	d2,d0			; tile number
	and.l	#$7ff,d0
	lsl.l	#7,d0
	CHIPB	CB_BGTILES,a2
	add.l	d0,a2
	tst.b	d1
	bpl.s	.noflip
	bsr	blit_wait		; the blitter may still read the last flipped tile
	CHIPA	CA_FLIPTILE,a3
	lea	rev_table(pc),a0
	moveq	#63,d2
.fl	moveq	#0,d0
	move.b	(a2)+,d0
	move.b	(a0,d0.w),d3
	move.b	(a2)+,d0
	move.b	(a0,d0.w),(a3)+
	move.b	d3,(a3)+
	dbf	d2,.fl
	CHIPA	CA_FLIPTILE,a2
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
	move.w	d1,d0
	lsr.w	#3,d0
	and.w	#15,d0
	bsr	get_slot
	move.w	d0,d1			; planes 4-7: the slot, all 0 or all 1
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
.x	movem.l	(sp)+,d0-d4/a0/a2/a3
	rts
.blank	moveq	#7,d2			; pen 15 (backdrop in every slot)
.bl	bsr	blit_wait
	move.w	#$01ff,d3
	cmp.w	#3,d2
	bhi.s	.b1
	move.w	#$0100,d3
.b1	move.w	d3,BLTCON0(a6)
	move.l	a0,BLTDPT(a6)
	move.w	#(16<<6)|1,BLTSIZE(a6)
	add.l	#PLANEALLOC,a0
	dbf	d2,.bl
	bra.s	.x

;------------------------------------------------------------------------------
; sprites as blitter objects. Each frame: put back the background saved under
; this buffer's objects (two frames ago), redraw the background, plan the
; objects from the buffered sprite RAM (entry 127 first, so entry 0 ends on
; top as on the arcade), save the background under all of them, draw them.

restore_bobs:
	move.w	pv_back(a4),d0
	lea	pv_nrec(a4),a0
	move.w	(a0,d0.w*2),d7
	beq.s	.x
	tst.b	clean_on(pc)
	bne	restore_clean
	bsr	blit_wait
	move.l	#-1,BLTAFWM(a6)
	clr.w	BLTCON1(a6)
	move.w	#$09f0,BLTCON0(a6)
	clr.w	BLTAMOD(a6)
	move.w	#LINEB-4,BLTDMOD(a6)
	move.l	pv_rec(a4),a2
	move.l	pv_save(a4),a3
	subq.w	#1,d7
.r	move.l	REC_DEST(a2),a0
	move.w	REC_H(a2),d1
	move.w	d1,d2
	lsl.w	#6,d2
	addq.w	#2,d2			; BLTSIZE: h lines x 2 words
	lsl.w	#2,d1			; bytes per plane in the save area
	moveq	#NPLANES-1,d6
.p	bsr	blit_wait
	move.l	a3,BLTAPT(a6)
	move.l	a0,BLTDPT(a6)
	move.w	d2,BLTSIZE(a6)
	add.w	d1,a3
	add.l	#PLANEALLOC,a0
	dbf	d6,.p
	lea	REC_SIZE(a2),a2
	dbf	d7,.r
.x	rts

; with the clean background: the same rectangles copied from it (d7 objects)
restore_clean:
	bsr	blit_wait
	move.l	#-1,BLTAFWM(a6)
	clr.w	BLTCON1(a6)
	move.w	#$09f0,BLTCON0(a6)
	move.w	#LINEB-4,BLTAMOD(a6)
	move.w	#LINEB-4,BLTDMOD(a6)
	move.l	pv_rec(a4),a2
	CHIPA	CA_CLEAN,a3
	sub.l	pv_bm(a4),a3		; clean - this buffer
	subq.w	#1,d7
.r	move.l	REC_DEST(a2),a0
	lea	(a0,a3.l),a1
	move.w	REC_H(a2),d2
	lsl.w	#6,d2
	addq.w	#2,d2			; BLTSIZE: h lines x 2 words
	moveq	#NPLANES-1,d6
.p	bsr	blit_wait
	move.l	a1,BLTAPT(a6)
	move.l	a0,BLTDPT(a6)
	move.w	d2,BLTSIZE(a6)
	add.l	#PLANEALLOC,a0
	add.l	#PLANEALLOC,a1
	dbf	d6,.p
	lea	REC_SIZE(a2),a2
	dbf	d7,.r
	rts

; with the clean background: every buffer slot of this buffer that doesn't
; hold what the clean one does gets its cell from there (or is forgotten
; with it). Copies only write the clean buffer's bytes, so cells that agree
; stay right however the memory columns overlap.
sync_clean:
	move.l	pv_sh(a4),a2
	lea	bgshadow0+NBUF*SHSIZE(pc),a3	; (the clean shadow is the last)
	moveq	#0,d5			; buffer slot
	moveq	#0,d2			; column slot * 4
	move.w	#16*NCOLSLOT-1,d7
	bsr	blit_setup
	move.w	#LINEB-2,BLTAMOD(a6)
	move.w	#$09f0,BLTCON0(a6)
.e	move.l	(a3)+,d0
	cmp.l	(a2)+,d0
	beq.s	.n
	move.l	d0,-4(a2)
	cmp.l	#-1,d0
	beq.s	.n
	move.l	d0,d1			; the cell: slot * 16 lines + memory column
	swap	d1
	and.w	#$ff,d1
	add.w	d1,d1
	move.w	d5,d3
	mulu.w	#16*LINEB,d3
	add.w	d1,d3
	move.l	pv_bm(a4),a0
	add.l	d3,a0
	CHIPA	CA_CLEAN,a1
	add.l	d3,a1
	moveq	#NPLANES-1,d6
.p	bsr	blit_wait
	move.l	a1,BLTAPT(a6)
	move.l	a0,BLTDPT(a6)
	move.w	#(16<<6)|1,BLTSIZE(a6)
	add.l	#PLANEALLOC,a0
	add.l	#PLANEALLOC,a1
	dbf	d6,.p
.n	addq.w	#4,d2
	cmp.w	#NCOLSLOT*4,d2
	bne.s	.c
	moveq	#0,d2
	addq.w	#1,d5
.c	dbf	d7,.e
	rts

save_bobs:
	bsr	blit_wait
	move.l	#-1,BLTAFWM(a6)
	clr.w	BLTCON1(a6)
	move.w	#$09f0,BLTCON0(a6)
	move.w	#LINEB-4,BLTAMOD(a6)
	clr.w	BLTDMOD(a6)
	move.l	pv_rec(a4),a2
	move.l	pv_save(a4),a3
	move.w	d7,d5
	subq.w	#1,d5
.r	move.l	REC_DEST(a2),a0
	move.w	REC_H(a2),d1
	move.w	d1,d2
	lsl.w	#6,d2
	addq.w	#2,d2
	lsl.w	#2,d1
	moveq	#NPLANES-1,d6
.p	bsr	blit_wait
	move.l	a0,BLTAPT(a6)
	move.l	a3,BLTDPT(a6)
	move.w	d2,BLTSIZE(a6)
	add.w	d1,a3
	add.l	#PLANEALLOC,a0
	dbf	d6,.p
	lea	REC_SIZE(a2),a2
	dbf	d5,.r
	rts

; cookie cut: D = A.B + !A.C for the pen planes, D = A + C or !A.C for the
; slot planes. A is the mask, 1 word wide read as 2 (modulo -2, last word
; masked off), shifted into place together with B.
blit_bobs:
	bsr	blit_wait
	move.w	#$ffff,BLTAFWM(a6)
	clr.w	BLTALWM(a6)
	move.w	#-2,BLTAMOD(a6)
	move.w	#-2,BLTBMOD(a6)
	move.w	#LINEB-4,BLTCMOD(a6)
	move.w	#LINEB-4,BLTDMOD(a6)
	move.l	pv_rec(a4),a2
	move.w	d7,d5
	subq.w	#1,d5
.r	move.l	REC_DEST(a2),a0
	move.w	REC_H(a2),d1
	lsl.w	#6,d1
	addq.w	#2,d1			; BLTSIZE
	move.w	REC_SHIFT(a2),d2
	move.l	REC_MASK(a2),d3
	move.l	REC_DATA(a2),a3
	move.w	REC_SLOT(a2),d4
	moveq	#3,d6
.p	bsr	blit_wait
	move.w	d2,d0
	or.w	#$0fca,d0
	move.w	d0,BLTCON0(a6)
	move.w	d2,BLTCON1(a6)
	move.l	d3,BLTAPT(a6)
	move.l	a3,BLTBPT(a6)
	move.l	a0,BLTCPT(a6)
	move.l	a0,BLTDPT(a6)
	move.w	d1,BLTSIZE(a6)
	lea	32(a3),a3
	add.l	#PLANEALLOC,a0
	dbf	d6,.p
	moveq	#3,d6
.k	bsr	blit_wait
	move.w	d2,d0
	or.w	#$0b0a,d0
	lsr.w	#1,d4
	bcc.s	.z
	or.w	#$00f0,d0
.z	move.w	d0,BLTCON0(a6)
	move.l	d3,BLTAPT(a6)
	move.l	a0,BLTCPT(a6)
	move.l	a0,BLTDPT(a6)
	move.w	d1,BLTSIZE(a6)
	add.l	#PLANEALLOC,a0
	dbf	d6,.k
	lea	REC_SIZE(a2),a2
	dbf	d5,.r
	rts

draw_bobs:
	move.w	pv_back(a4),d0
	lea	pv_nrec(a4),a0
	clr.w	(a0,d0.w*2)
	btst	#2,pv_iod+$c(a4)		; sprites off?
	bne	.x
	bsr	blit_wait		; (flipbuf is free again)
	bsr	bob_cutoff
	move.l	pv_rec(a4),a2
	CHIPA	CA_FLIPBUF,a3
	moveq	#0,d7			; objects
	clr.w	pv_saverows(a4)
	moveq	#NSPR-1,d6
.spr	cmp.w	pv_bobcut(a4),d6	; (no room for it: lower priority)
	bhs	.next
	lea	pv_sprsnap(a4),a0
	lea	(a0,d6.w*4),a0
	moveq	#0,d5
	move.b	2(a0),d5		; y
	beq	.next
	cmp.w	#240,d5
	bhs	.next
	moveq	#0,d1
	move.b	1(a0),d1		; attribute
	moveq	#0,d2
	move.b	3(a0),d2		; x
	btst	#4,d1
	beq.s	.xp
	sub.w	#256,d2
.xp	cmp.w	#-15,d2
	blt	.next
	moveq	#0,d0
	move.w	d1,d0
	and.w	#$e0,d0
	lsl.w	#3,d0
	move.b	(a0),d0			; sprite number
	lea	sprrows(pc),a1
	move.w	(a1,d0.w*2),d3		; first row << 8 | rows (0: empty)
	beq	.next
	swap	d3
	move.l	d0,d4
	moveq	#7,d0
	and.w	d1,d0
	add.w	#16,d0
	bsr	get_slot
	move.w	d0,d3			; slot; the rows in the upper word
	move.l	d4,d0
	CHIPB	CB_SPRMASK,a0
	move.l	d0,d4
	lsl.l	#5,d4
	add.l	d4,a0
	CHIPB	CB_SPRITES,a1
	lsl.l	#7,d0
	add.l	d0,a1
	btst	#3,d1
	beq.s	.nf
	bsr	get_flipped
.nf	swap	d3			; only the rows with pixels in them
	moveq	#0,d0
	move.b	d3,d0
	move.w	d0,d4			; rows
	lsr.w	#8,d3			; first row
	add.w	d3,d5
	add.w	d3,d3
	add.w	d3,a0
	add.w	d3,a1
	move.w	d4,d3
	swap	d3			; rows << 16 | slot
	add.w	pv_vx(a4),d2
	add.w	#COLBIAS*16,d2		; x in the buffer
	moveq	#15,d4
	and.w	d2,d4
	ror.w	#4,d4			; shift << 12
	asr.w	#4,d2
	add.w	d2,d2
	ext.l	d2			; byte offset of the first word
	add.w	pv_vy(a4),d5
	sub.w	#16,d5
	and.w	#255,d5			; first buffer line
	moveq	#0,d0
	move.w	d5,d0
	mulu.w	#LINEB,d0
	add.l	pv_bm(a4),d0
	add.l	d2,d0
	move.l	d0,(a2)+		; REC_DEST
	move.l	d3,d0
	swap	d0			; rows
	add.w	d0,pv_saverows(a4)	; (room to save the background under it?)
	tst.b	clean_on(pc)
	bne.s	.room
	cmp.w	#SAVESIZE/SAVE_ROW,pv_saverows(a4)
	bhi	.full
.room
	move.w	#BUFH,d1
	sub.w	d5,d1			; lines before the buffer wraps
	cmp.w	d0,d1
	blo.s	.h
	move.w	d0,d1
.h	move.w	d1,(a2)+		; REC_H
	move.w	d4,(a2)+		; REC_SHIFT
	move.l	a0,(a2)+		; REC_MASK
	move.l	a1,(a2)+		; REC_DATA
	move.w	d3,(a2)+		; REC_SLOT
	addq.l	#2,a2
	addq.w	#1,d7
	cmp.w	d0,d1
	beq.s	.next
	sub.w	d1,d0			; the rest from buffer line 0
	move.w	d0,-(sp)
	move.l	pv_bm(a4),d0
	add.l	d2,d0
	move.l	d0,(a2)+
	move.w	(sp)+,(a2)+
	move.w	d4,(a2)+
	add.w	d1,d1
	lea	(a0,d1.w),a0
	lea	(a1,d1.w),a1
	move.l	a0,(a2)+
	move.l	a1,(a2)+
	move.w	d3,(a2)+
	addq.l	#2,a2
	addq.w	#1,d7
.next	cmp.w	#2*MAXBOB-1,d7		; (room for MAXBOB sprites)
	dbhs	d6,.spr
	bra.s	.planned
.full	subq.l	#4,a2			; (REC_DEST written already)
.planned
	move.w	pv_back(a4),d0
	lea	pv_nrec(a4),a0
	move.w	d7,(a0,d0.w*2)
	tst.w	d7
	beq.s	.x
	tst.b	clean_on(pc)		; (the clean background: nothing to save)
	bne.s	.ns
	bsr	save_bobs
.ns	bsr	blit_bobs
.x	rts

; d4 = sprite number * 32, a1 = sprite, a0 = its mask -> a1, a0 = x-flipped
; copies: from the cache of recently flipped sprites (64, by sprite number),
; else made there - or at a3 (moves on) if that cache entry is in use this
; frame already
get_flipped:
	movem.l	d0-d1/a2,-(sp)
	move.l	d4,d0
	lsr.l	#5,d0			; sprite number
	moveq	#63,d1
	and.w	d0,d1
	lea	fliptag(pc),a2
	lea	(a2,d1.w*4),a2		; tag.w, frame.w
	cmp.w	(a2),d0
	beq.s	.hit
	move.w	2(a2),d0
	cmp.w	pv_drawn(a4),d0
	beq.s	.temp			; holds another sprite this frame
	move.l	d4,d0
	lsr.l	#5,d0
	move.w	d0,(a2)
	move.w	pv_drawn(a4),2(a2)
	move.l	a3,-(sp)
	mulu.w	#160,d1
	CHIPA	CA_FLIPCACHE,a3
	add.l	d1,a3
	bsr	flip_sprite
	move.l	(sp)+,a3
	bra.s	.x
.hit	move.w	pv_drawn(a4),2(a2)
	mulu.w	#160,d1
	CHIPA	CA_FLIPCACHE,a1
	add.l	d1,a1
	lea	128(a1),a0
	bra.s	.x
.temp	bsr	flip_sprite
.x	movem.l	(sp)+,d0-d1/a2
	rts

fliptag:	ds.l	64		; flip cache: sprite number, frame last used

; With more sprites than room (MAXBOB, SAVESIZE), the ones with the lowest
; priority (highest numbers) are left out: pv_bobcut = the first left out.
bob_cutoff:
	movem.l	d0-d4/a0-a1,-(sp)
	lea	pv_sprsnap(a4),a0
	lea	sprrows(pc),a1
	moveq	#0,d3			; lines to save
	moveq	#0,d4			; sprites
	moveq	#0,d2			; sprite number
.s	move.b	2(a0),d0		; y: on screen?
	beq.s	.n
	cmp.b	#240,d0
	bhs.s	.n
	moveq	#0,d0
	move.b	1(a0),d0
	moveq	#0,d1
	move.b	3(a0),d1
	btst	#4,d0
	beq.s	.xp
	sub.w	#256,d1
.xp	cmp.w	#-15,d1
	blt.s	.n
	and.w	#$e0,d0
	lsl.w	#3,d0
	move.b	(a0),d0
	moveq	#0,d1
	move.b	1(a1,d0.w*2),d1		; its lines
	beq.s	.n
	add.w	d1,d3
	addq.w	#1,d4
	cmp.w	#SAVESIZE/SAVE_ROW,d3
	bhi.s	.cut
	cmp.w	#MAXBOB,d4
	bhi.s	.cut
.n	addq.l	#4,a0
	addq.w	#1,d2
	cmp.w	#NSPR,d2
	bne.s	.s
.cut	move.w	d2,pv_bobcut(a4)
	movem.l	(sp)+,d0-d4/a0-a1
	rts

; a1 = sprite (4 planes x 16 words), a0 = its mask -> x-flipped copies at a3
; (a1, a0 then point at them; a3 moves on)
flip_sprite:
	movem.l	d0-d2/a2,-(sp)
	lea	rev_table(pc),a2
	move.l	a3,-(sp)
	moveq	#63,d2
.d	moveq	#0,d0
	move.b	(a1)+,d0
	move.b	(a2,d0.w),d1
	move.b	(a1)+,d0
	move.b	(a2,d0.w),(a3)+
	move.b	d1,(a3)+
	dbf	d2,.d
	moveq	#15,d2
.m	moveq	#0,d0
	move.b	(a0)+,d0
	move.b	(a2,d0.w),d1
	move.b	(a0)+,d0
	move.b	(a2,d0.w),(a3)+
	move.b	d1,(a3)+
	dbf	d2,.m
	move.l	(sp)+,a1
	lea	128(a1),a0
	movem.l	(sp)+,d0-d2/a2
	rts

;------------------------------------------------------------------------------
; copper list for the next frame
COPMOVE	macro
	move.l	#((\1)<<16)|((\2)&$ffff),(a0)+
	endm

; palette RAM changed? (background 0-255, sprites $200-$27F, text $300-$37F,
; compared with the shadow 4 bytes at a time) -> recompute those colours
	Z80	ZDA00,$da00
	Z80	ZDE00,$de00
	Z80	ZDB00,$db00
	Z80	ZDF00,$df00
	Z80	ZDBFC,$dbfc
	Z80	ZDFFC,$dffc
update_palette:
	lea	palshadow(pc),a3
	moveq	#0,d2			; anything changed?
	not.b	pv_palhalf(a4)		; half of it each frame
	beq.s	.h2
	lea	(ZD800,a5),a0		; background, low bytes
	moveq	#64-1,d1
	bsr.s	.cmp
	lea	(ZDC00,a5),a0		; background, high bytes
	moveq	#64-1,d1
	bsr.s	.cmp
	bra.s	.hx
.h2	lea	512(a3),a3
	lea	(ZDA00,a5),a0		; sprites
	moveq	#32-1,d1
	bsr.s	.cmp
	lea	(ZDE00,a5),a0
	moveq	#32-1,d1
	bsr.s	.cmp
	lea	(ZDB00,a5),a0		; text
	moveq	#32-1,d1
	bsr.s	.cmp
	lea	(ZDF00,a5),a0
	moveq	#32-1,d1
	bsr.s	.cmp
	lea	(ZDBFC,a5),a0		; backdrop (entry 1023), low and high
	moveq	#0,d1
	bsr.s	.cmp
	lea	(ZDFFC,a5),a0
	moveq	#0,d1
	bsr.s	.cmp
.hx	tst.w	d2
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
.bg	bsr.s	.pal16			; background 0-255
	cmp.w	#256,d3
	bne.s	.bg
	move.w	#$200,d3		; sprites (pv_sprgb follows pv_rgb)
.sp	bsr.s	.pal16
	cmp.w	#$280,d3
	bne.s	.sp
	lea	pv_txrgb(a4),a2
	move.w	#$300,d3
.tx	move.w	d3,d0
	bsr	pal_rgb
	move.w	d0,(a2)+
	addq.w	#1,d3
	cmp.w	#$380,d3
	bne.s	.tx
	lea	pv_blank(a4),a2
	moveq	#14,d0
.bk	clr.w	(a2)+
	dbf	d0,.bk
	move.w	#$3ff,d0
	bsr	pal_rgb
	move.w	d0,(a2)
	move.w	#(1<<NBUF)-1,pv_paldirty(a4)	; all copper lists
	addq.w	#1,pv_textver(a4)
	rts
; 16 colours from palette entry d3 to (a2); pen 15 (transparent) is the backdrop
.pal16	moveq	#14,d4
.p	move.w	d3,d0
	bsr	pal_rgb
	move.w	d0,(a2)+
	addq.w	#1,d3
	dbf	d4,.p
	move.w	#$3ff,d0
	bsr	pal_rgb
	move.w	d0,(a2)+
	addq.w	#1,d3
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

; d6 = slot -> a2 = its 16 colours
slot_colours:
	lea	pv_blank(a4),a2
	cmp.w	#NSLOTS,d6
	bhs.s	.x
	moveq	#0,d0
	move.b	pv_pal_of(a4,d6.w),d0
	bmi.s	.x
	lsl.w	#5,d0
	lea	pv_rgb(a4),a2		; (pv_sprgb follows: palettes 16-23)
	add.w	d0,a2
.x	rts

build_copper:
	lea	pvars(pc),a4
	lea	z80mem+$8000(pc),a5
	CHIPA	CA_COPLIST0,a0
	move.w	pv_back(a4),d0
	mulu.w	#COPSIZE,d0
	add.l	d0,a0
	lea	coplist_ptr(pc),a2
	move.l	a0,(a2)

	; palette section (fixed size, at the start): rewritten only when stale
	move.w	pv_back(a4),d0		; (a count instead missed a buffer that
	bclr	d0,pv_paldirty+1(a4)	; wasn't drawn into: wrong colours there)
	beq.s	.palok
	moveq	#0,d4			; colour bank: 2 slots
	moveq	#0,d6			; slot
.bank	move.w	#BPLCON3,(a0)+
	move.w	d4,d1
	ror.w	#3,d1
	or.w	#$0040,d1		; lowres sprites
	move.w	d1,(a0)+
	move.w	#COLOR00,d1
	moveq	#1,d3
.slot	bsr	slot_colours
	moveq	#15,d5
.col	move.w	d1,(a0)+
	move.w	(a2)+,(a0)+
	addq.w	#2,d1
	dbf	d5,.col
	addq.w	#1,d6
	dbf	d3,.slot
	addq.w	#1,d4
	cmp.w	#8,d4
	bne.s	.bank			; leaves BPLCON3 at bank 7 for the text colours
	bra.s	.paldone
.palok	lea	PALSECT(a0),a0
.paldone
	COPMOVE	FMODE,$000d		; 32-bit bitplane, 64-bit sprite fetch
	COPMOVE	BPLCON0,$0211		; 8 planes
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
	COPMOVE	BPLCON4,$00fe		; sprite colours: even 240-255, odd 224-239
	COPMOVE	DIWSTRT,(DISP_Y0<<8)|$a1
	COPMOVE	DIWSTOP,(((DISP_Y0+VIEW_H)&255)<<8)|$a1
	COPMOVE	DDFSTRT,$0038
	COPMOVE	DDFSTOP,$00b8
	COPMOVE	BPL1MOD,MODULO
	COPMOVE	BPL2MOD,MODULO

	; bitplane pointers
	move.w	pv_vy(a4),d1
	and.w	#255,d1
	mulu.w	#LINEB,d1		; buffer line at the top of the view
	move.w	pv_vx(a4),d2
	add.w	#COLBIAS*16+31,d2
	lsr.w	#5,d2
	lsl.w	#2,d2
	ext.l	d2
	subq.l	#4,d2
	add.l	d2,d1
	add.l	pv_bm(a4),d1
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

	; sprite pointers: text (if enabled)
	move.w	#SPR0PTH,d3
	moveq	#0,d7
.spr	CHIPA	CA_NULLSPR,a3
	move.l	a3,d1
	btst	#7,pv_iod+4(a4)		; characters off?
	bne.s	.sset
	move.w	d7,d1
	mulu.w	#TXSPR_SIZE,d1
	CHIPA	CA_TXSPR,a3
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

	; the rest (text colours, buffer wrap) only when it changed for this list
	move.w	#BUFH-1,d6
	sub.w	pv_vy(a4),d6
	and.w	#255,d6
	swap	d6
	move.w	pv_textver(a4),d6
	lea	pv_csig(a4),a2
	move.w	pv_back(a4),d0
	cmp.l	(a2,d0.w*4),d6
	bne.s	.text
	rts
.text	move.l	d6,(a2,d0.w*4)

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
.d	lea	pv_rowpal(a4),a2	; colours 241-243, ... (even sprites),
	move.w	d5,d0			; 225-227, ... (odd sprites)
	lsl.w	#3,d0
	add.w	d0,a2
	move.w	#COLOR00+17*2,d2
	move.w	#COLOR00+1*2,d6
	moveq	#3,d7
.sp4	bsr	tx_cols
	exg	d2,d6
	bsr	tx_cols
	exg	d2,d6
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

; (a2)+ = text palette, d2 = its first colour register -> 3 copper moves
tx_cols:
	moveq	#$1f,d0
	and.b	(a2)+,d0
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
bss_size:		dc.l	bss_end-bss_start	; (for tools/build_game.py: BSS,
			dc.l	CHIPA_FAST		; chip area A in fast RAM mode,
			dc.l	CHIPB_SIZE		; chip area B,
			dc.l	SOUND_SIZE		; its sound part)
snd_on:			dc.b	0		; room for sound: it plays
snd_nomusic:		dc.b	0		; music off (effects only): without fast RAM
clean_on:		dc.b	0		; the clean background buffer (fast RAM)
			even
chipa:			dc.l	0		; chip RAM areas (see the end of the file)
chipb:			dc.l	0

;------------------------------------------------------------------------------
	cnop	0,4
pvars:		ds.b	pv_size
		ds.b	2048
plat_stack_top:
		ds.b	4096
disp_stack_top:
rev_table:	ds.b	256

	include	"game.s"


charblank:	incbin	"charblank.bin"
	cnop	0,8
z80rom:		incbin	"z80fixed.bin"	; (copied at boot; then display buffers)

; packed data (tools/lzpack.py), unpacked at boot into the BSS
	cnop	0,8
packed:
lz_banks:	incbin	"z80banks.lz"
lz_tiles:	incbin	"bgtiles.lz"
lz_chars:	incbin	"chars.lz"
lz_sprites:	incbin	"sprites.lz"
packed_end:

; Chip RAM, in two areas (chipa, chipb). Without fast RAM everything is in
; the one chip RAM block the bootblock loads into: area A (display buffers)
; reuses the space of the fixed ROM copy and the packed data once they are
; unpacked, area B follows the BSS.
; With fast RAM the program and its data are there, and both areas are a
; separate chip RAM block.
CA_BITMAP0	equ	16			; NBUF bitmaps
CA_COPLIST0	equ	CA_BITMAP0+NBUF*BMSIZE	; NBUF copper lists
CA_TXSPR	equ	CA_COPLIST0+NBUF*COPSIZE
CA_NULLSPR	equ	CA_TXSPR+8*TXSPR_SIZE
CA_FLIPBUF	equ	CA_NULLSPR+32
CA_FLIPCACHE	equ	CA_FLIPBUF+MAXBOB*160	; 64 x 160
CA_FLIPTILE	equ	CA_FLIPCACHE+64*160
CA_SAVE0	equ	CA_FLIPTILE+128		; NBUF save areas
CHIPA_SIZE	equ	CA_SAVE0+NBUF*SAVESIZE
	ifgt	CHIPA_SIZE-(packed_end-z80rom)
	fail	"display buffers don't fit in the fixed ROM copy + packed data's space"
	endif
; with fast RAM (a chip RAM block of their own) no save areas: a clean copy of
; the background instead (clean_on), sprites restored from it
CA_CLEAN	equ	CA_SAVE0
	ifgt	BMSIZE-NBUF*SAVESIZE
CHIPA_FAST	equ	CA_CLEAN+BMSIZE
	else
CHIPA_FAST	equ	CHIPA_SIZE
	endif
CB_BGTILES	equ	0			; blitter sources
CB_SPRITES	equ	CB_BGTILES+2048*128
CB_SPRMASK	equ	CB_SPRITES+2048*128
CB_AUDIO	equ	CB_SPRMASK+2048*32	; the sound player's output
CHIPB_SIZE	equ	(CB_AUDIO+PLAY_BUFSIZE+7)&-8
; the sound data, at the end of the program's block (in fast RAM if any) by
; the bootblock (src/boot.s), from the disk after the payload: the sound CPU's
; memory from $C000 (the player's tables in it), its ROM, the bank
SOUND_SIZE	equ	$4000+$8000+BANK_SIZE

; BSS: allocated (cleared) by the bootblock right after the loaded file
	cnop	0,8
bss_start:
z80banks	equ	bss_start
chars		equ	z80banks+16*16384
sprrows		equ	chars+2048*16		; per sprite: first row << 8 | rows
z80mem		equ	sprrows+2048*2
bgram		equ	z80mem+65536
task_stacks	equ	bgram+16384
bgshadow0	equ	task_stacks+16*1024	; NBUF background shadows (+ the clean one)
rec0		equ	bgshadow0+(NBUF+1)*SHSIZE	; NBUF object lists
txshadow	equ	rec0+NBUF*RECSIZE
palshadow	equ	txshadow+2048		; 1032 bytes
snd_rt		equ	palshadow+1032+8	; the sound CPU's runtime (src/sound.s)
ym_regs		equ	snd_rt+((RT_SIZE+3)&-4)
ym_keyon	equ	ym_regs+512
bss_end		equ	ym_keyon+8
