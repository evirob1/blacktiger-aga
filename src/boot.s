; Black Tiger AGA - bootblock
; On the disk after it: the payload, then the sound data (the sound program's
; ROM and the instrument bank), each packed by tools/lzpack.py, then the
; effects' samples (tools/sound/effects.py, not packed).
; The payload is loaded below the top of its memory block and unpacked to the
; bottom (BSS after it); the sound data at the end of the block, its packed
; form just below. Where the packed data was is zeroed again, as allocated.
; Then the payload starts with A6 = ExecBase, A3 = a separate chip RAM block
; or 0, A2 = the sound data (its ROM, after a 16K window) or 0, D6 = the
; effects' samples or 0, D5 = how many of their bytes were read:
;  * fast RAM: the payload, its BSS and the sound data go into fast RAM, the
;    display's chip RAM areas into a chip RAM block of their own (A3)
;  * otherwise everything goes into one chip RAM block (A3 = 0), with the
;    effects' samples at its end instead of the sound data; if that won't
;    fit, without the optional ones at their end (the story tune), else
;    without any (the game runs silent)
; Sizes and offsets are patched in by tools/mkadf.py.

	section	boot,code

	dc.b	'DOS',0
	dc.l	0			; checksum (mkadf.py)
	dc.l	880			; root block

	move.l	a1,a5			; trackdisk IORequest
	move.l	fast_size(pc),d0
	move.l	#$10004,d1		; MEMF_FAST|MEMF_CLEAR
	jsr	-198(a6)		; AllocMem
	move.l	d0,a4
	tst.l	d0
	beq.s	.stock
	move.l	chip_size(pc),d0
	move.l	#$10002,d1		; MEMF_CHIP|MEMF_CLEAR
	jsr	-198(a6)
	move.l	d0,a3
	tst.l	d0
	beq.s	.nochip
	move.l	a4,a2			; sound: at the end of the fast block,
	add.l	snd_at_fast(pc),a2
	lea	-$4000(a2),a0		; the payload's packed data below it
	move.l	a0,d7
	moveq	#0,d6
	bra.s	.load
.nochip	move.l	a4,a1			; no room in chip RAM after all: one block
	move.l	fast_size(pc),d0
	jsr	-210(a6)		; FreeMem
.stock	sub.l	a3,a3
	move.l	stock_size(pc),d0
	move.l	#$10002,d1
	jsr	-198(a6)
	tst.l	d0
	bne.s	.st
	move.l	stock_lite(pc),d0	; short: without the optional effects (the
	move.l	#$10002,d1		; last of them)
	jsr	-198(a6)
	tst.l	d0
	beq.s	.quiet
	lea	fx_load(pc),a0
	move.l	fx_lite(pc),(a0)
.st	move.l	d0,a4
	sub.l	a2,a2			; the effects at the end of the block, the
	move.l	a4,d6			; payload's packed data below them
	add.l	fx_at_stock(pc),d6
	move.l	d6,d7
	tst.l	fx_load(pc)
	bne.s	.load
	moveq	#0,d6
	bra.s	.load
.quiet	sub.l	a2,a2			; without the sound data: silent
	moveq	#0,d6
	move.l	stock_quiet(pc),d0
	move.l	#$10002,d1
	jsr	-198(a6)
	tst.l	d0
	beq	.fail
	move.l	d0,a4
	move.l	a4,d7
	add.l	stock_quiet(pc),d7
.load	move.l	d7,a0			; the payload: packed at the top, unpacked
	sub.l	load_size(pc),a0	; to the bottom (the output stays below)
	move.l	#1024,d0
	move.l	load_size(pc),d1
	bsr	read
	move.l	a0,d5
	move.l	a4,a1
	bsr	unpack
	cmp.l	d5,a1			; zero where the packed data was, past the output
	bhs.s	.pz
	move.l	d5,a1
.pz	bsr	clear
	move.l	sound_load(pc),d1	; (none on the disk: silent)
	beq.s	.nosnd
	move.l	a2,d0			; the sound data: packed just below its window
	beq.s	.go			; ($C000-$FFFF, under the ROM), unpacked to
	lea	-$4000(a2),a0		; the ROM's place (above it)
	move.l	a0,d7
	sub.l	d1,a0
	move.l	#1024,d0
	add.l	load_size(pc),d0
	bsr	read
	move.l	a0,d5
	move.l	a2,a1
	bsr	unpack
	move.l	d5,a1
	bsr	clear
	bra.s	.go
.nosnd	sub.l	a2,a2
.go	move.l	d6,d0			; the effects: read in place
	beq.s	.mot
	move.l	d0,a0
	move.l	#1024,d0
	add.l	load_size(pc),d0
	add.l	sound_load(pc),d0
	move.l	fx_load(pc),d1
	bsr	read
.mot	move.l	a5,a1
	move.w	#9,28(a1)		; TD_MOTOR
	clr.l	36(a1)			; off
	jsr	-456(a6)
	jsr	-636(a6)		; CacheClearU: the code was written as data
	move.l	fx_load(pc),d5		; (the effects' bytes read)
	jmp	(a4)
.fail	move.w	#$f00,$dff180
	bra.s	.fail

; read d1 bytes from disk offset d0 to a0 (keeps a0)
read:	move.l	a0,-(sp)
	move.l	a5,a1
	move.w	#2,28(a1)		; CMD_READ
	move.l	a0,40(a1)		; io_Data
	move.l	d1,36(a1)		; io_Length
	move.l	d0,44(a1)		; io_Offset
	jsr	-456(a6)		; DoIO
	move.l	(sp)+,a0
	tst.b	31(a5)			; io_Error
	bne.s	.f
	rts
.f	move.w	#$f00,$dff180
	bra.s	.f

; unpack a0 -> a1 (as lz_unpack in src/amiga_main.s): a1 = the output's end
unpack:	moveq	#0,d0
	move.b	(a0)+,d0
	bmi.s	.match
.lit	move.b	(a0)+,(a1)+
	dbf	d0,.lit
	bra.s	unpack
.match	cmp.b	#$ff,d0
	beq.s	.end
	and.w	#$7f,d0
	addq.w	#2,d0
	moveq	#0,d1
	move.b	(a0)+,d1
	lsl.w	#8,d1
	move.b	(a0)+,d1
	move.l	a0,d2
	move.l	a1,a0
	sub.l	d1,a0
.cp	move.b	(a0)+,(a1)+
	dbf	d0,.cp
	move.l	d2,a0
	bra.s	unpack
.end	rts

; zero from a1 to d7
clear:	cmp.l	d7,a1
	bhs.s	.x
	clr.b	(a1)+
	bra.s	clear
.x	rts

load_size	dc.l	0		; patched: the packed payload, rounded to 512
sound_load	dc.l	0		; patched: the packed sound data, rounded to 512
fast_size	dc.l	0		; patched: payload (unpacked) + BSS + the sound data
chip_size	dc.l	0		; patched: chip areas A + B
stock_size	dc.l	0		; patched: payload + BSS + chip area B
stock_quiet	dc.l	0		; patched: the same without the sound data
snd_at_fast	dc.l	0		; patched: the sound ROM's place in the fast block
fx_at_stock	dc.l	0		; patched: the effects' place in the one block
fx_load		dc.l	0		; patched: the effects, rounded to 512 (0: none)
stock_lite	dc.l	0		; patched: stock_size without the optional effects
fx_lite		dc.l	0		; patched: fx_load without them
