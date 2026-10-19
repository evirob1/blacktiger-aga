; Black Tiger AGA - bootblock
; Loads the payload that follows the bootblock on disk into chip RAM and
; jumps to it with A6 = ExecBase. Sizes are patched in by tools/mkadf.py.

	section	boot,code

	dc.b	'DOS',0
	dc.l	0			; checksum (mkadf.py)
	dc.l	880			; root block

	move.l	a1,a5			; trackdisk IORequest
	move.l	alloc_size(pc),d0
	move.l	#$10002,d1		; MEMF_CHIP|MEMF_CLEAR
	jsr	-198(a6)		; AllocMem
	tst.l	d0
	beq.s	.fail
	move.l	d0,a4
	move.l	a5,a1
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
alloc_size	dc.l	0		; patched: payload + bss
