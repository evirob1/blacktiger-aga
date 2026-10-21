; Black Tiger AGA - bootblock
; Loads the payload that follows the bootblock on disk (packed by
; tools/lzpack.py) to the top of its memory block, unpacks it to the bottom,
; clears the rest (BSS) and jumps to it with A6 = ExecBase and A3 = a separate
; chip RAM block, or 0:
;  * fast RAM: the payload and its BSS go into fast RAM, the display's chip
;    RAM areas into a chip RAM block of their own (A3)
;  * otherwise everything goes into one chip RAM block (A3 = 0)
; Sizes are patched in by tools/mkadf.py.

	section	boot,code

	dc.b	'DOS',0
	dc.l	0			; checksum (mkadf.py)
	dc.l	880			; root block

	move.l	a1,a5			; trackdisk IORequest
	move.l	fast_size(pc),d7
	move.l	d7,d0
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
	bne.s	.load
	move.l	a4,a1			; no room in chip RAM after all: one block
	move.l	d7,d0
	jsr	-210(a6)		; FreeMem
.stock	move.l	stock_size(pc),d7
	move.l	d7,d0
	move.l	#$10002,d1		; MEMF_CHIP|MEMF_CLEAR
	jsr	-198(a6)
	tst.l	d0
	beq	.fail
	move.l	d0,a4
	sub.l	a3,a3
.load	lea	(a4,d7.l),a2		; the end of the block
	move.l	a2,d6
	sub.l	load_size(pc),a2	; the packed payload: at the top
	move.l	a5,a1
	move.w	#2,28(a1)		; CMD_READ
	move.l	a2,40(a1)		; io_Data
	move.l	load_size(pc),36(a1)	; io_Length
	move.l	#1024,44(a1)		; io_Offset
	jsr	-456(a6)		; DoIO
	tst.b	31(a5)			; io_Error
	bne	.fail
	move.l	a5,a1
	move.w	#9,28(a1)		; TD_MOTOR
	clr.l	36(a1)			; off
	jsr	-456(a6)
	move.l	a2,d5
	move.l	a2,a0			; unpack to the bottom (lz_unpack in
	move.l	a4,a1			; src/amiga_main.s; the output stays below)
.tok	moveq	#0,d0
	move.b	(a0)+,d0
	bmi.s	.match
.lit	move.b	(a0)+,(a1)+
	dbf	d0,.lit
	bra.s	.tok
.match	cmp.b	#$ff,d0
	beq.s	.end
	and.w	#$7f,d0
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
.end	cmp.l	d5,a1			; where the packed payload was: zero again,
	bhs.s	.clr			; as allocated
	move.l	d5,a1
.clr	clr.b	(a1)+
	cmp.l	d6,a1
	blo.s	.clr
	jsr	-636(a6)		; CacheClearU: the code was written as data
	jmp	(a4)
.fail	move.w	#$f00,$dff180
	bra.s	.fail

load_size	dc.l	0		; patched: packed payload size rounded to 512
fast_size	dc.l	0		; patched: payload (unpacked) + BSS
chip_size	dc.l	0		; patched: chip areas A + B
stock_size	dc.l	0		; patched: payload + BSS + chip area B
