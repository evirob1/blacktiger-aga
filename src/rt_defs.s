; Black Tiger AGA - definitions shared by the translated programs' runtimes
; (src/rt_core.s: the game's main CPU; src/sound.s: the sound CPU)

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
RT_ALT_BC	equ	72	; w  BC'
RT_BGPTR	equ	74	; l  bgram + bank * $1000 + $4000: (RT_BGPTR, Z80 address.w)
RT_JPFROM	equ	78	; l  bank << 16 | address of the last jp (hl)/(ix)/(iy)
RT_SIZE		equ	82
