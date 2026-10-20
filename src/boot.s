; Black Tiger AGA - bootblock
; Loads the payload that follows the bootblock on disk and jumps to it with
; A6 = ExecBase and A3 = a separate chip RAM block, or 0:
;  * fast RAM: the payload and its BSS go into fast RAM, the display's chip
;    RAM areas into a chip RAM block of their own (A3)
;  * otherwise everything goes into one chip RAM block (A3 = 0)
; Sizes are patched in by tools/mkadf.py.

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
	bne.s	.load
	move.l	a4,a1			; no room in chip RAM after all: one block
	move.l	fast_size(pc),d0
	jsr	-210(a6)		; FreeMem
.stock	move.l	stock_size(pc),d0
	move.l	#$10002,d1		; MEMF_CHIP|MEMF_CLEAR
	jsr	-198(a6)
	tst.l	d0
	beq.s	.fail
	move.l	d0,a4
	sub.l	a3,a3
.load	move.l	a5,a1
	move.w	#2,28(a1)		; CMD_READ
	move.l	a4,40(a1)		; io_Data
	move.l	load_size(pc),36(a1)	; io_Length
	move.l	#1024,44(a1)		; io_Offset
	jsr	-456(a6)		; DoIO
	tst.b	31(a5)			; io_Error
	bne.s	.fail
	move.l	a5,a1
	move.w	#9,28(a1)		; TD_MOTOR
	clr.l	36(a1)			; off
	jsr	-456(a6)
	jmp	(a4)
.fail	move.w	#$f00,$dff180
	bra.s	.fail

load_size	dc.l	0		; patched: payload size rounded to 512
fast_size	dc.l	0		; patched: payload + BSS
chip_size	dc.l	0		; patched: chip areas A + B
stock_size	dc.l	0		; patched: payload + BSS + chip area B
