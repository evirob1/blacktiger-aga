"""Z80 instruction timings (T-states), for the cycle-counting test build.

tstates(mem, pc) -> (t, extra_if_taken)
"""

# unprefixed opcodes; conditional ones give the not-taken time here
MAIN = [
    4, 10, 7, 6, 4, 4, 7, 4, 4, 11, 7, 6, 4, 4, 7, 4,
    8, 10, 7, 6, 4, 4, 7, 4, 12, 11, 7, 6, 4, 4, 7, 4,
    7, 10, 16, 6, 4, 4, 7, 4, 7, 11, 16, 6, 4, 4, 7, 4,
    7, 10, 13, 6, 11, 11, 10, 4, 7, 11, 13, 6, 4, 4, 7, 4,
] + [4] * 64 + [4] * 64 + [
    5, 10, 10, 10, 10, 11, 7, 11, 5, 10, 10, 0, 10, 17, 7, 11,
    5, 10, 10, 11, 10, 11, 7, 11, 5, 4, 10, 11, 10, 0, 7, 11,
    5, 10, 10, 19, 10, 11, 7, 11, 5, 4, 10, 4, 10, 0, 7, 11,
    5, 10, 10, 4, 10, 11, 7, 11, 5, 6, 10, 4, 10, 0, 7, 11,
]
for _op in range(0x40, 0x80):                 # ld r,(hl) / ld (hl),r
    if (_op & 7) == 6 or (_op >> 3 & 7) == 6:
        MAIN[_op] = 7
MAIN[0x76] = 4                                 # halt
for _op in range(0x80, 0xC0):                 # alu a,(hl)
    if (_op & 7) == 6:
        MAIN[_op] = 7

TAKEN_EXTRA = {0x10: 5, 0x20: 5, 0x28: 5, 0x30: 5, 0x38: 5}
for _op in (0xC0, 0xC8, 0xD0, 0xD8, 0xE0, 0xE8, 0xF0, 0xF8):
    TAKEN_EXTRA[_op] = 6                       # ret cc: 5 / 11
for _op in (0xC4, 0xCC, 0xD4, 0xDC, 0xE4, 0xEC, 0xF4, 0xFC):
    TAKEN_EXTRA[_op] = 7                       # call cc: 10 / 17

# DD/FD prefixed: opcodes that use (ix+d)
IDX_MEM = {0x34: 23, 0x35: 23, 0x36: 19}
for _op in range(0x40, 0x80):
    if ((_op & 7) == 6) != ((_op >> 3 & 7) == 6):
        IDX_MEM[_op] = 19
for _op in range(0x80, 0xC0):
    if (_op & 7) == 6:
        IDX_MEM[_op] = 19
IDX_OTHER = {0x21: 14, 0x22: 20, 0x2A: 20, 0x23: 10, 0x2B: 10, 0x09: 15, 0x19: 15, 0x29: 15,
             0x39: 15, 0xE1: 14, 0xE5: 15, 0xE9: 8, 0xE3: 23, 0xF9: 10}


def tstates(mem, pc):
    op = mem[pc & 0xFFFF]
    if op in (0xDD, 0xFD):
        op2 = mem[(pc + 1) & 0xFFFF]
        if op2 == 0xCB:
            sub = mem[(pc + 3) & 0xFFFF]
            return (20 if 0x40 <= sub < 0x80 else 23), 0
        if op2 in IDX_MEM:
            return IDX_MEM[op2], 0
        if op2 in IDX_OTHER:
            return IDX_OTHER[op2], 0
        t, x = tstates(mem, pc + 1)           # ixh/ixl forms and ignored prefixes
        return t + 4, x
    if op == 0xCB:
        sub = mem[(pc + 1) & 0xFFFF]
        if (sub & 7) == 6:
            return (12 if 0x40 <= sub < 0x80 else 15), 0
        return 8, 0
    if op == 0xED:
        sub = mem[(pc + 1) & 0xFFFF]
        if sub in (0xB0, 0xB8, 0xB1, 0xB9, 0xB2, 0xBA, 0xB3, 0xBB):
            return 16, 5                       # repeats: 21 per iteration, 16 for the last
        if sub in (0xA0, 0xA8, 0xA1, 0xA9, 0xA2, 0xAA, 0xA3, 0xAB):
            return 16, 0
        if sub & 0xC7 == 0x40 or sub & 0xC7 == 0x41:
            return 12, 0                       # in r,(c) / out (c),r
        if sub & 0xC7 == 0x42:
            return 15, 0                       # sbc/adc hl,rr
        if sub & 0xC7 == 0x43:
            return 20, 0                       # ld (nn),rr / ld rr,(nn)
        if sub in (0x44, 0x4C, 0x54, 0x5C, 0x64, 0x6C, 0x74, 0x7C):
            return 8, 0                        # neg
        if sub & 0xC7 == 0x45:
            return 14, 0                       # retn / reti
        if sub & 0xC7 == 0x46:
            return 8, 0                        # im
        if sub in (0x47, 0x4F, 0x57, 0x5F):
            return 9, 0
        if sub in (0x67, 0x6F):
            return 18, 0                       # rrd / rld
        return 8, 0
    return MAIN[op], TAKEN_EXTRA.get(op, 0)
