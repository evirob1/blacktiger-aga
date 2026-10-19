# Z80 → 68020 translator: design

The main Z80 program is converted to 68020 source once, at build time, from
the user's ROM set. The output is assembled with vasm together with a
hand-written runtime (scheduler, banking, video/sound glue).

## Finding the code

`tools/z80/codemap.py` does recursive descent from the reset and interrupt
vectors, following the ROM bank number through `out ($01),a` and the bank
setter at `$034B`. Almost all game code runs as scheduler tasks started
through `jp (hl)`, so static descent alone finds very little. Entry points
recorded while MAME runs the game (instruction trace, `tools/mame/`) seed it;
static descent then covers the branches the recording didn't take.

## The scheduler (fixed ROM `$00B3`–`$014B`)

16 task slots of 8 bytes at `$E880`:

| byte | meaning |
|---|---|
| 0 | state: 0 free, 1 sleeping, 2 running, 4 ready to resume, 8 new (not started) |
| 1 | sleep counter (frames) |
| 2–3 | start address (new task) or saved SP (sleeping task) |

| Routine | Call | Effect |
|---|---|---|
| `$00F6` | A = slot, BC = entry | create task |
| `$0109` | A = slot | kill task |
| `$0116` | A = frames | sleep: push all registers, save SP, go to scheduler |
| `$0135` | | end the current task |

The interrupt (`$0038`) comes once per frame, at the start of the frame
(measured in MAME: every 100,608 Z80 cycles; the driver source suggests two
per frame, but only one happens). It decrements sleep counters and marks
finished sleepers ready.

The port keeps the arcade's structure: the reset code ends in the scheduler's
endless loop and the interrupt arrives from outside, between any two Z80
instructions, gated by the program's own `di`/`ei`. A long task is therefore
interrupted in the middle, exactly as on the board, and game speed and slowdown
behave like the original. The scheduler loop, task start/resume and sleep are
hand-written in `src/rt_core.s`, instruction for instruction with the Z80
original (including the `di`/`ei` windows), so interrupts land at the same
points.

## Register and memory mapping

| Z80 | 68k |
|---|---|
| A | `d0.b` |
| BC, DE, HL | `d1.w`, `d2.w`, `d3.w` (low byte = C/E/L; B/D/H via `rol.w #8` sequences) |
| IX, IY | `d4.w`, `d5.w` |
| BC', DE', HL' (`exx`) | `a1`, `a2`, `a3` (swapped with `exg`) |
| A', F' (`ex af,af'`) | runtime variables |
| runtime variables | `a4` |
| Z80 cycle counter | `a5` (test build only) |
| memory base | `a6` = Z80 memory + `$8000`, with the two 32K halves swapped |
| scratch | `d6`, `d7`, `a0` |
| stack | `a7`: native 68k stack, `bsr`/`rts` for `call`/`ret` |

Swapping the halves means a Z80 address held in a register works directly
as a signed 16-bit index: `ld a,(hl)` → `move.b (a6,d3.w),d0`.

**Banked ROM.** Code in `$8000`–`$BFFF` is translated per bank, and labels
carry the bank (`b6_8c76`). The game switches banks up to ~26 times a frame,
so a switch only moves `a1` to the bank's data. Reads of banked data use it:
fixed addresses in `$8000`–`$BFFF` statically, block moves by checking their
source once, and the instructions listed in `data/bank_reads.txt` (recorded
in MAME by `tools/mame/bank_reads.sh`) by checking their pointer at run time.
The test harness leaves the Z80 image's bank window unfilled and reports any
other read of it, so a missing site can't go unnoticed in testing.

**Video RAM** (`$C000`–`$FFFF`) is plain memory. The runtime diffs it each
frame against a shadow copy to find changed tiles, characters and colours.
The background RAM window (4 × 4K banks behind `$C000`) is swapped on
`out ($0D)`.

## Flags

Z, C, S and P/V (as overflow) map onto 68k Z, C, N and V. H and N are only
needed by `daa`; `add`/`adc`/`sub` + `daa` sequences become `abcd`/`sbcd`.
Many 68k instructions change flags where the Z80 one doesn't (`ld` → `move`,
`inc rr`, …), so a liveness pass marks where Z80 flags are still needed. At
those points the translator saves and restores the CCR (`move ccr,dN` /
`move dN,ccr`). Parity after logic ops (`jp pe/po`) gets a table lookup if
it's ever used.

Jump tables are also read straight from the ROM: wherever `ld hl,TABLE` reaches
the dispatcher at `$0408` (or the same lookup written inline ending in
`jp (hl)`) with HL otherwise unchanged, the table's entries become entry points.
A table ends at the first entry that isn't a code pointer, where it runs into
code or into one of its own targets. This finds object behaviours the MAME
recordings never reached (e.g. the 53-entry state table at `$4751`).

## Indirect jumps

`jp (hl)`, task entry addresses and jump tables use Z80 addresses as data.
The translator emits a sorted (bank, address) → 68k label table with every
translated instruction in it (computed jumps also land on code that is
otherwise reached by falling through), and the runtime looks targets up by
binary search; addresses in `$8000`–`$BFFF` use the current ROM bank.

## Stack tricks

`tools/z80/codemap.py` (`stack_depths`) tracks how many bytes each routine has
pushed at every instruction:

* `pop` at depth 0 takes the return address: on the 68k that is 4 bytes, so it
  becomes `addq.l #4,sp` ("abort to the caller's caller"; later pops read the
  caller's own pushes as usual).
* `pop hl / inc hl × k / jp (hl)` returns to the return address + k. The call
  sites of such routines (`$039C`, `$03B2`, `$0412`, `$043B`, `$5367`) get a
  table of `bra.w` entries, one per Z80 byte offset, and the routine jumps to
  entry k.
* `ld hl,<code> / push hl` followed later by `ret` (a hand-pushed return
  address) pushes the 68k address of that code (`pea`). One case: `$1970`.
* Each task starts on its own stack (`ld sp,$E340` etc.): one 68k stack per
  Z80 stack address.
* `$0135` (end task) never returns.

## Hand-written parts

* the scheduler: `$00B3`–`$00F5` (scan loop, start, resume) and `$0116`–`$0134` (sleep).
  Its own `ei`s go through the platform's `PLAT_EI`: on the Amiga that delivers a
  vblank interrupt that arrived while interrupts were off (the Z80's interrupt
  line stays asserted until accepted);
* I/O ports: inputs, sound latch, bank switch, scroll, video enable, MCU (port 7).

## Verification

`tools/harness/` runs the translated program on the Musashi 68020 emulator
under Linux, built with `--cycles`: every translated instruction starts with a
`nop` (an instruction-boundary marker) and adds its Z80 T-states to `a5`. The
harness raises the interrupt every 100,608 T-states, at the first boundary
where the game has interrupts enabled (with the Z80's one-instruction delay
after `ei`), so it lands on the same instruction as in MAME.

`tools/mame/record.lua` records a MAME run: every I/O read (replayed to the
translated program, so inputs, DIP switches, the vblank flag and the
protection MCU's answers are identical) and a snapshot of game RAM, background
RAM, text RAM and palette at each interrupt. The harness compares all of it at
the same moment.

```
tools/harness/run.sh            # translate, assemble, compare with analysis/rec
build/harness build/harness_game.bin analysis/rec/io.txt analysis/rec/ram.bin
```

`BT_TRACE=lo,hi` logs every instruction boundary with its cycle count;
`tools/harness/cmp_trace.py` lines that up with a MAME `trace` (with
`totalcycles`) and reports where the timing differs.

**Status:** a 3,000-frame recording (attract mode, coin, start, random play)
matches MAME byte for byte at every frame.

## Speed

`BT_PROFILE=1 build/harness ...` counts 68k cycles spent on game work (not the
idle loop, not the test instrumentation) per frame, using Musashi's 68020
timings (no chip RAM wait states), and writes `build/profile.txt`.

Over the 3,000-frame recording: mean 18,500, median 3,300, 90th percentile
54,000, 99th 110,000, worst 219,000 cycles per frame. A PAL frame on a 14 MHz
68020 is ~283,000 cycles, so the game logic should leave most of the frame for
rendering even with chip RAM wait states. Biggest remaining costs: background
RAM bank switching (21%, 2 × 4K copy) and the computed-jump lookup (5%).
