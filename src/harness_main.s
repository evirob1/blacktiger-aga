; Black Tiger AGA - translated game for the Linux test harness (tools/harness)
; I/O ports are memory mapped: reads $FF0000+port, writes $FF0100+port.
; Built with the translator's --cycles option: a5 counts Z80 T-states and a
; nop marks every Z80 instruction boundary, where the harness may interrupt.

	machine	68020

PLAT_IN	macro
	move.b	($ff0000+\1).l,d0
	endm

PLAT_OUT macro
	move.b	d0,($ff0100+\1).l
	endm

CYC	macro
	lea	\1(a5),a5
	endm

BOUNDARY macro
	nop
	endm

PLAT_IDLE macro
	endm

PLAT_DI	macro
	endm

PLAT_HIT macro
	endm

PLAT_LEVEL macro
	endm

PLAT_EI	macro				; the harness raises interrupts itself
	st	RT_IE(a4)
	endm

	include	"rt_core.s"

bg_mark_d2:				; (the A1200 display notes background writes)
bg_mark_d3:
bg_mark_up:
bg_mark_down:
	rts

z80_ei:
	st	RT_IE(a4)
	rts

z80_bad_jump:
	move.l	d7,($ff0300).l
.halt	bra.s	.halt

plat_irq:				; level 3 autovector, raised by the harness
	movem.l	d0-d7/a0/a2-a4/a6,-(sp)	; not a5 (cycle counter) or a1 (bank: global)
	bsr	rt_irq_body
	movem.l	(sp)+,d0-d7/a0/a2-a4/a6
	rte

	include	"game.s"

	cnop	0,4
z80rom:		incbin	"z80fixed.bin"
z80banks:	incbin	"z80banks.bin"
task_stacks:	ds.b	16*1024
z80mem:		ds.b	65536
bgram:		ds.b	16384
